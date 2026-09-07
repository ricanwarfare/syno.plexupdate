"""Execute updater sections with fixtures; never call real NAS services."""
import io
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / 'syno.plexupdate.sh').read_text()


def section(start, end):
    return SCRIPT[SCRIPT.index(start):SCRIPT.index(end, SCRIPT.index(start))]


def run(code, **values):
    env = dict(os.environ, **{k: str(v) for k, v in values.items()})
    return subprocess.run(['bash', '-uc', 'set -o pipefail\n' + code],
                          env=env, text=True, capture_output=True)


class UpdaterTests(unittest.TestCase):
    def test_competing_run_keeps_lock_and_owner_cleans_up(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / 'lock'
            code = section('# ACQUIRE AN ATOMIC LOCK', '# REDIRECT STDOUT')
            code = code.replace('/tmp/syno.plexupdate.lock.d', str(lock))
            owner = subprocess.Popen(['bash', '-c', code + '\necho ready; read -r release'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(owner.stdout.readline().strip(), 'ready')
                contender = run(code)
                self.assertEqual(contender.returncode, 1)
                self.assertTrue(lock.is_dir())
            finally:
                owner.communicate('release\n', timeout=5)
            self.assertEqual(owner.returncode, 0)
            self.assertFalse(lock.exists())

    def test_numeric_settings(self):
        code = section('# Validate numeric settings', '# CHECK FOR BASIC INTERNET')
        values = dict(MinimumAge='08', OldUpdates='060', NetTimeout='900', SelfUpdate='0')
        result = run(code + '\nprintf "%s %s" "$MinimumAge" "$OldUpdates"', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '8 60')
        for key, value in [('OldUpdates', '-1'), ('MinimumAge', 'abc'),
                           ('NetTimeout', '10000000000'), ('SelfUpdate', 'yes')]:
            with self.subTest(key=key):
                self.assertEqual(run(code, **dict(values, **{key: value})).returncode, 1)

    def test_token_absent_from_trace(self):
        code = section('# SCRAPE PLEX ONLINE TOKEN WITHOUT', '# SCRAPE PLEX SERVER UPDATE CHANNEL')
        code += section('if [ -z "$PlexChannl" ]; then', '# SCRAPE PLEX WEBSITE')
        code += section('# DISABLE XTRACE TEMPORARILY', 'if [ "$_curl_rc"')
        # Mock grep and curl, allowing tests to run on macOS as well as Linux.
        result = run('grep() { printf "%s" "$TEST_TOKEN"; }; curl() { echo "{}"; }; set -x\n' + code,
                     TEST_TOKEN='private-test-token', PlexFolder='/unused', PlexChannl='8', NetTimeout='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('private-test-token', result.stderr + result.stdout)

    def test_update_requires_install_and_restart_success(self):
        code = section('strip_build_version() {', '# CHECK IF ROOT')
        code += """
synopkg() {
  echo "$1" >> "$CALL_LOG"
  case "$1" in
    stop) return "$STOP_RC" ;;
    install) echo '{"results": []}'; return "$INSTALL_RC" ;;
    start) return "$START_RC" ;;
    version) echo '1.3.0-build' ;;
  esac
}
synonotify() { :; }
dpkg() { return 0; }
tar() { return 0; }
"""
        code += section('# COMPARE PLEX VERSIONS', '# EXIT NORMALLY')
        code = code.replace('/usr/bin/dpkg', 'dpkg').replace('/usr/syno/bin/synopkg', 'synopkg')
        code = code.replace('/usr/syno/bin/synonotify', 'synonotify')
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'Archive' / 'Packages'
            archive.mkdir(parents=True)
            (archive / 'PlexMediaServer.spk').touch()
            values = dict(SrceFolder=tmp, RunVersion='1.2.0', NewVersion='1.3.0',
                          NewPackage='PlexMediaServer.spk', PackageAge='10', MinimumAge='7',
                          SkipAgeCheck='false', NewVerDate='', ChannlName='Public',
                          NewVerAddd='', NewVerFixd='', STOP_RC='0', INSTALL_RC='0',
                          START_RC='0', CALL_LOG=str(Path(tmp) / 'calls'))
            result = run(code, **values)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('succeeded!', result.stdout)
            for overrides in [dict(INSTALL_RC='1'), dict(START_RC='1')]:
                with self.subTest(overrides=overrides):
                    result = run(code, **dict(values, **overrides))
                    self.assertIn('failed!', result.stdout)
                    self.assertNotIn('succeeded!', result.stdout)
            Path(values['CALL_LOG']).write_text('')
            self.assertEqual(run(code, **dict(values, STOP_RC='1')).returncode, 1)
            self.assertEqual(Path(values['CALL_LOG']).read_text(), 'stop\n')

    def test_invalid_release_date_does_not_pass_zero_day_threshold(self):
        code = section(
            '  # CALCULATE NEW PACKAGE AGE', '\nelse\n  printf')
        for value in ['', 'null', 'nonsense', '0', '999999999999999999999999']:
            with self.subTest(value=value):
                result = run(code + '\ntest "$PackageAge" -lt 0',
                             NewVerDate=value, TodaysDate='1800000000')
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rollback_selects_version_and_returns_failures(self):
        with tempfile.TemporaryDirectory(prefix='plex tests ') as tmp:
            archive = Path(tmp) / 'Archive' / 'Packages'
            archive.mkdir(parents=True)
            comparator = Path(tmp) / 'compare'
            comparator.write_text('''#!/usr/bin/env python3
import sys
a, op, b = sys.argv[2:]
a = tuple(map(int, a.split('.')))
b = tuple(map(int, b.split('.')))
sys.exit(0 if {'lt': a < b, 'gt': a > b, 'eq': a == b}[op] else 1)
''')
            comparator.chmod(0o700)
            code = section('strip_build_version() {', '# CHECK IF ROOT')
            code += '''
synopkg() {
  echo "$1" >> "$CALL_LOG"
  case "$1" in
    stop) return "$STOP_RC" ;;
    install) echo '{"results": []}'; return "$INSTALL_RC" ;;
    start) return "$START_RC" ;;
    version) echo "$AFTER_VERSION" ;;
  esac
}
synonotify() { :; }
'''
            code += section('# ROLLBACK FUNCTIONALITY', 'if [ -z "$PlexChannl" ]; then')
            code = code.replace('/usr/bin/dpkg', shlex.quote(str(comparator)))
            code = code.replace('/usr/syno/bin/synopkg', 'synopkg').replace('/usr/syno/bin/synonotify', 'synonotify')
            values = dict(SrceFolder=tmp, Rollback='true', RunVersion='1.4.0',
                          STOP_RC='0', INSTALL_RC='0', START_RC='0', AFTER_VERSION='1.3.0',
                          CALL_LOG=str(Path(tmp) / 'calls'))

            def package(version):
                with tarfile.open(archive / ('PlexMediaServer-' + version + '.spk'), 'w') as tar:
                    data = ('version="' + version + '-build"\n').encode()
                    info = tarfile.TarInfo('INFO')
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))

            package('1.3.0')
            result = run(code, **values)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('succeeded!', result.stdout)
            # A newer download and an older package must not change the selection.
            package('1.5.0')
            package('1.1.0')
            self.assertIn('PlexMediaServer-1.3.0.spk', run(code, **values).stdout)
            for overrides in [dict(INSTALL_RC='1'), dict(START_RC='1'),
                              dict(AFTER_VERSION='1.4.0'), dict(AFTER_VERSION='')]:
                with self.subTest(overrides=overrides):
                    Path(values['CALL_LOG']).write_text('')
                    result = run(code, **dict(values, **overrides))
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertNotIn('succeeded!', result.stdout)
                    self.assertIn('start', Path(values['CALL_LOG']).read_text())
            Path(values['CALL_LOG']).write_text('')
            self.assertEqual(run(code, **dict(values, STOP_RC='1')).returncode, 1)
            self.assertEqual(Path(values['CALL_LOG']).read_text(), 'stop\n')
            self.assertEqual(run(code, **dict(values, RunVersion='1.0.0')).returncode, 1)


if __name__ == '__main__':
    unittest.main()
