"""Full entrypoint in a private fixture tree; all services/network are stubs."""
import io
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'syno.plexupdate.sh'


class RecoveryTests(unittest.TestCase):
    def fixture(self, tmp, state='running'):
        root = Path(tmp)
        bindir = root / 'bin'
        bindir.mkdir()
        (root / 'state').write_text(state)
        (root / 'version').write_text('1.4.0')
        (root / 'VERSION').write_text('productversion="7.2.2"\nbuildnumber="123"\n')
        (root / 'config.ini').write_text('SelfUpdate=1\nMinimumAge=2\nOldUpdates=10\nNetTimeout=1\nSkipAgeCheck=0\n')
        archive = root / 'Archive/Packages'
        archive.mkdir(parents=True)
        for version in ['1.3.0', '1.5.0']:
            with tarfile.open(archive / ('PlexMediaServer-' + version + '.spk'), 'w') as tar:
                data = ('version="' + version + '-build"\n').encode()
                member = tarfile.TarInfo('INFO')
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        scripts = {
            'synopkg': '''#!/bin/bash
printf '%s\\n' "$1" >> "$FIXTURE/calls"
case "$1" in
 status) printf '{"status":"%s"}\\n' "$(< "$FIXTURE/state")" ;;
 version) cat "$FIXTURE/version" ;;
 stop) echo stopped > "$FIXTURE/state"; if [ "${BLOCK_STOP:-0}" = 1 ]; then touch "$FIXTURE/stopping"; sleep 1; fi ;;
 start) test ! -e "$FIXTURE/installing" || { echo overlap >> "$FIXTURE/calls"; exit 1; }; echo running > "$FIXTURE/state" ;;
 install)
   touch "$FIXTURE/installing"
   if [ "${BLOCK_INSTALL:-0}" = 1 ]; then sleep 1; fi
   case "$2" in *1.3.0*) echo 1.3.0 > "$FIXTURE/version";; *) echo 1.5.0 > "$FIXTURE/version";; esac
   rm "$FIXTURE/installing"
   echo install-finished >> "$FIXTURE/calls"
   echo '{"results":[]}'
   exit "${INSTALL_RC:-0}" ;;
esac
''',
            'synonotify': '#!/bin/bash\nexit 0\n',
            'nslookup': '#!/bin/bash\necho dns >> "$FIXTURE/network"\nexit "${OFFLINE:-0}"\n',
            'ping': '#!/bin/bash\necho ping >> "$FIXTURE/network"\nexit 1\n',
            'wget': '#!/bin/bash\necho wget >> "$FIXTURE/network"\nexit 1\n',
            'curl': '''#!/bin/bash
echo curl >> "$FIXTURE/network"
case "$*" in
 *api.github.com*) echo '[]';;
 *) echo '{"nas":{"synology-dsm72":{"version":"1.5.0-build","release_date":1000000000,"releases":[{"build":"linux-x86_64","url":"https://invalid/PlexMediaServer-1.5.0.spk"}]}}}';;
esac
''',
        }
        for name, text in scripts.items():
            file = bindir / name
            file.write_text(text)
            file.chmod(0o700)
        code = SOURCE.read_text().replace('/tmp/syno.plexupdate.lock.d', str(root / 'lock'))
        code = code.replace('/usr/syno/bin/synopkg', str(bindir / 'synopkg'))
        code = code.replace('/usr/syno/bin/synonotify', str(bindir / 'synonotify'))
        code = code.replace('/bin/wget', str(bindir / 'wget'))
        code = code.replace('/etc.defaults/VERSION', str(root / 'VERSION'))
        code = code.replace('/var/packages/PlexMediaServer/shares/PlexMediaServer', str(root / 'missing-share'))
        code = code.replace('PlexFolder="$PlexFolder/AppData/Plex Media Server"',
                            'PlexFolder=' + str(root / 'plex-fixture'))
        code = code.replace('if [ "$EUID" -ne "0" ]; then', 'if false; then')
        script = root / 'updater.sh'
        script.write_text(code)
        return root, dict(os.environ, FIXTURE=tmp, PATH=str(bindir) + ':' + os.environ['PATH'])

    def test_offline_rollback_bypasses_all_network_even_selfupdate_master(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, env = self.fixture(tmp)
            result = subprocess.run(['bash', str(root / 'updater.sh'), '-r', '-m'], env=dict(env, OFFLINE='1'), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / 'network').exists())
            self.assertEqual((root / 'version').read_text().strip(), '1.3.0')

    def interrupted(self, rollback, state='running', during_stop=False, sig=signal.SIGTERM):
        with tempfile.TemporaryDirectory() as tmp:
            root, env = self.fixture(tmp, state)
            env.update(BLOCK_INSTALL='0' if during_stop else '1', BLOCK_STOP='1' if during_stop else '0')
            proc = subprocess.Popen(['bash', str(root / 'updater.sh')] + (['-r'] if rollback else []), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                marker = root / ('stopping' if during_stop else 'installing')
                deadline = time.monotonic() + 8
                while not marker.exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(marker.exists(), 'mock did not reach interruption point')
                proc.send_signal(sig)
                # Cancellation waits for the in-flight package operation. A
                # second signal and competing entrypoint must not unlock it.
                time.sleep(.1)
                self.assertIsNone(proc.poll())
                self.assertTrue((root / 'lock').is_dir())
                proc.send_signal(sig)
                contender = subprocess.run(['bash', str(root / 'updater.sh'), '-r'], env=env,
                                           capture_output=True, text=True, timeout=3)
                self.assertEqual(contender.returncode, 1)
                self.assertIn('Another instance', contender.stdout)
                out, err = proc.communicate(timeout=8)
                self.assertEqual(proc.returncode, 128 + sig, out + err)
                self.assertEqual((root / 'state').read_text().strip(), state)
                calls = (root / 'calls').read_text().splitlines()
                self.assertNotIn('overlap', calls)
                self.assertFalse((root / 'installing').exists())
                self.assertFalse((root / 'lock').exists())
                if not during_stop and state == 'running':
                    self.assertLess(calls.index('install-finished'), calls.index('start'))
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate(timeout=5)

    def test_signal_between_launch_and_pid_assignment_recovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, env = self.fixture(tmp)
            script = root / 'updater.sh'
            script.write_text(script.read_text().replace('  PackagePID=$!\n', '  kill -TERM "$$"\n  PackagePID=$!\n'))
            result = subprocess.run(['bash', str(script), '-r'], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
            self.assertEqual((root / 'state').read_text().strip(), 'running')
            self.assertFalse((root / 'lock').exists())
            self.assertNotIn('install', (root / 'calls').read_text().splitlines())

    def test_term_update_waits_for_installer_before_recovery(self):
        self.interrupted(False)

    def test_term_rollback_waits_for_installer_before_recovery(self):
        self.interrupted(True)

    def test_int_rollback_waits_for_installer_before_recovery(self):
        self.interrupted(True, sig=signal.SIGINT)

    def test_unknown_initial_state_refuses_before_stop_or_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, env = self.fixture(tmp, 'unknown')
            result = subprocess.run(['bash', str(root / 'updater.sh'), '-r'], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            calls = (root / 'calls').read_text().splitlines()
            self.assertNotIn('stop', calls)
            self.assertNotIn('install', calls)
            self.assertFalse((root / 'lock').exists())

    def test_hup_rollback_waits_for_installer_before_recovery(self):
        self.interrupted(True, sig=signal.SIGHUP)

    def test_term_during_stop_recovers(self):
        self.interrupted(True, during_stop=True)

    def test_term_preserves_initially_stopped(self):
        self.interrupted(True, state='stopped')

    def test_normal_and_failed_install_preserve_initially_stopped(self):
        for rollback in [False, True]:
            for rc in ['0', '1']:
                with self.subTest(rollback=rollback, rc=rc), tempfile.TemporaryDirectory() as tmp:
                    root, env = self.fixture(tmp, 'stopped')
                    result = subprocess.run(['bash', str(root / 'updater.sh')] + (['-r'] if rollback else []), env=dict(env, INSTALL_RC=rc), capture_output=True, text=True, timeout=10)
                    self.assertEqual((root / 'state').read_text().strip(), 'stopped', result.stdout + result.stderr)
                    self.assertNotIn('start', (root / 'calls').read_text().splitlines())
                    self.assertFalse((root / 'lock').exists())


if __name__ == '__main__':
    unittest.main()
