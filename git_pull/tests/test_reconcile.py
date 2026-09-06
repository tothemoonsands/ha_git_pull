"""Exercise production reconciliation against real, isolated Git repositories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'data/git-reconcile.sh'


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remote.git'
        self.publisher = self.root / 'publisher'
        self.checkout = self.root / 'checkout'
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
        self.git(self.root, 'init', '--bare', str(self.remote))
        self.git(self.root, 'clone', str(self.remote), str(self.publisher))
        self.git(self.publisher, 'checkout', '-b', 'main')
        self.identity(self.publisher)
        for path, content in [('dashboard.yaml', 'old dashboard\n'),
                              ('scripts.yaml', 'old script\n'),
                              ('other.yaml', 'original\n'), ('.gitignore', 'ignored*\n')]:
            (self.publisher / path).write_text(content)
        self.publish()
        self.git(self.root, 'clone', '-b', 'main', str(self.remote), str(self.checkout))
        self.identity(self.checkout)
        self.old = self.git(self.checkout, 'rev-parse', 'HEAD')

    def git(self, cwd, *args):
        result = subprocess.run(['git', *args], cwd=cwd, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def identity(self, cwd):
        self.git(cwd, 'config', 'user.name', 'Test')
        self.git(cwd, 'config', 'user.email', 'test@example.invalid')

    def publish(self):
        self.git(self.publisher, 'add', '-A')
        self.git(self.publisher, 'commit', '-m', 'Configuration update')
        self.git(self.publisher, 'push', 'origin', 'main')

    def incoming(self, **files):
        for name, content in files.items():
            (self.publisher / name).write_text(content)
        self.publish()
        self.git(self.checkout, 'fetch', 'origin', 'refs/heads/main')
        return self.git(self.checkout, 'rev-parse', 'FETCH_HEAD')

    def run_sync(self, target='FETCH_HEAD', enabled='true', shim=''):
        command = '''
set -euo pipefail
bashio::log.info() { printf '%s\\n' "$*"; }
bashio::log.warning() { printf '%s\\n' "$*"; }
bashio::log.error() { printf '%s\\n' "$*"; }
source "$1"
''' + shim + '\nif git-pull-fetched "$2" "$3"; then exit 0; else exit $?; fi\n'
        return subprocess.run(['bash', '-c', command, 'test', str(HELPER), target, enabled],
                              cwd=self.checkout, env=self.env, capture_output=True, text=True)

    def head(self):
        return self.git(self.checkout, 'rev-parse', 'HEAD')

    def recovery_refs(self):
        return self.git(self.checkout, 'for-each-ref', '--format=%(refname)',
                        'refs/git-pull/recovery/').splitlines()

    def test_clean_fast_forward_and_second_poll(self):
        target = self.incoming(**{'dashboard.yaml': 'published\n'})
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), target)
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.recovery_refs(), [])

    def test_matching_direct_edit_heals_and_keeps_snapshot(self):
        target = self.incoming(**{'dashboard.yaml': 'published\n', 'scripts.yaml': 'new script\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(), target)
        self.assertEqual(self.git(self.checkout, 'status', '--porcelain'), '')
        refs = self.recovery_refs()
        self.assertEqual(len(refs), 1)
        self.assertEqual(self.git(self.checkout, 'show', refs[0] + ':dashboard.yaml'), 'published')
        self.assertEqual((self.checkout / 'scripts.yaml').read_text(), 'new script\n')
        self.git(self.checkout, 'reflog', 'expire', '--expire=now', '--all')
        self.git(self.checkout, 'prune', '--expire=now')
        self.assertEqual(self.git(self.checkout, 'show', refs[0] + ':dashboard.yaml'), 'published')
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.recovery_refs(), refs)

    def test_unpublished_edit_defers_then_heals_after_push(self):
        self.incoming(**{'dashboard.yaml': 'remote version\n'})
        (self.checkout / 'dashboard.yaml').write_text('direct deployment\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.recovery_refs(), [])
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'direct deployment\n')
        target = self.incoming(**{'dashboard.yaml': 'direct deployment\n'})
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), target)

    def test_mixed_matching_and_unique_edits_are_preserved(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        (self.checkout / 'other.yaml').write_text('local only\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.recovery_refs(), [])
        self.assertEqual((self.checkout / 'other.yaml').read_text(), 'local only\n')

    def test_staged_snapshot_is_never_reconciled(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('staged local\n')
        self.git(self.checkout, 'add', 'dashboard.yaml')
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.git(self.checkout, 'show', ':dashboard.yaml'), 'staged local')
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'published\n')
        self.assertEqual(self.recovery_refs(), [])

    def test_untracked_and_ignored_files_survive_success(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        for name in ['dashboard.yaml', 'untracked-local', 'ignored-local']:
            (self.checkout / name).write_text('published\n')
        self.assertEqual(self.run_sync().returncode, 0)
        for name in ['untracked-local', 'ignored-local']:
            self.assertEqual((self.checkout / name).read_text(), 'published\n')

    def test_untracked_collision_restores_stashed_edits(self):
        self.incoming(**{'dashboard.yaml': 'published\n', 'new.yaml': 'remote\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        (self.checkout / 'new.yaml').write_text('local only\n')
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'published\n')
        self.assertEqual((self.checkout / 'new.yaml').read_text(), 'local only\n')
        self.assertEqual(len(self.recovery_refs()), 1)

    def test_untracked_directory_cannot_be_removed_by_stash(self):
        (self.publisher / 'dashboard.yaml').unlink()
        (self.publisher / 'scripts.yaml').write_text('published\n')
        self.publish()
        self.git(self.checkout, 'fetch', 'origin', 'main')
        (self.checkout / 'scripts.yaml').write_text('published\n')
        (self.checkout / 'dashboard.yaml').unlink()
        (self.checkout / 'dashboard.yaml').mkdir()
        private = self.checkout / 'dashboard.yaml/ignored-private'
        private.write_text('keep me\n')
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(private.read_text(), 'keep me\n')
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.recovery_refs(), [])

    def test_ignored_collision_is_not_overwritten(self):
        (self.publisher / 'ignored-new').write_text('remote\n')
        self.git(self.publisher, 'add', '-f', 'ignored-new')
        self.publish()
        self.git(self.checkout, 'fetch', 'origin', 'main')
        (self.checkout / 'ignored-new').write_text('private local\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual((self.checkout / 'ignored-new').read_text(), 'private local\n')
        self.assertEqual(self.head(), self.old)

    def test_divergence_does_not_merge_or_reset(self):
        self.incoming(**{'dashboard.yaml': 'remote\n'})
        (self.checkout / 'other.yaml').write_text('local commit\n')
        self.git(self.checkout, 'commit', '-am', 'Local commit')
        local = self.head()
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), local)
        self.assertEqual(self.recovery_refs(), [])

    def test_disabled_reconciliation_keeps_edits(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        self.assertNotEqual(self.run_sync(enabled='false').returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual(self.recovery_refs(), [])

    def test_existing_user_stash_is_retained(self):
        (self.checkout / 'other.yaml').write_text('user stash\n')
        self.git(self.checkout, 'stash', 'push', '-m', 'User stash')
        previous = self.git(self.checkout, 'rev-parse', 'refs/stash')
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'stash@{1}'), previous)

    def test_recovery_ref_failure_restores_edits(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        result = self.run_sync(shim='git() { if [[ "$1" == update-ref ]]; then return 1; fi; command git "$@"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'published\n')
        self.assertTrue(self.git(self.checkout, 'rev-parse', 'refs/stash'))

    def test_edit_during_preflight_is_saved_and_restored(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        shim = '''git() {
 if [[ "$1" == stash && "$2" == push ]]; then printf 'new concurrent edit\\n' > other.yaml; fi
 command git "$@"
}'''
        result = self.run_sync(shim=shim)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.checkout / 'other.yaml').read_text(), 'new concurrent edit\n')
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'published\n')
        self.assertEqual(len(self.recovery_refs()), 1)

    def test_literal_unusual_paths(self):
        name = 'a [literal]\nfile.yaml'
        (self.publisher / name).write_text('old\n')
        self.publish()
        self.git(self.checkout, 'pull', '--ff-only', 'origin', 'main')
        self.incoming(**{name: 'new\n'})
        (self.checkout / name).write_text('new\n')
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.checkout, 'status', '--porcelain'), '')

    def test_matching_deletion_and_file_mode(self):
        (self.publisher / 'dashboard.yaml').unlink()
        (self.publisher / 'scripts.yaml').chmod(0o755)
        self.publish()
        self.git(self.checkout, 'fetch', 'origin', 'main')
        (self.checkout / 'dashboard.yaml').unlink()
        (self.checkout / 'scripts.yaml').chmod(0o755)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.checkout, 'status', '--porcelain'), '')

    def test_active_git_operation_is_left_alone(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / '.git/MERGE_HEAD').write_text(self.old + '\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertTrue((self.checkout / '.git/MERGE_HEAD').exists())

    def test_merge_autostash_configuration_cannot_hide_conflicts(self):
        self.git(self.checkout, 'config', 'merge.autostash', 'true')
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('private local edit\n')
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'private local edit\n')


class AddonLoopTests(unittest.TestCase):
    setUp = ReconcileTests.setUp
    git = ReconcileTests.git
    identity = ReconcileTests.identity
    publish = ReconcileTests.publish
    incoming = ReconcileTests.incoming
    head = ReconcileTests.head
    # Run only the integration tests here; unit cases remain on ReconcileTests.
    def run_addon(self, repeat='false', remote='origin'):
        run_script = HELPER.with_name('run.sh')
        command = r"""
set -euo pipefail
bashio::config() {
 case "$1" in
  git_branch) echo main ;;
  git_remote) echo "$TEST_REMOTE" ;;
  repository) echo "$TEST_REPOSITORY" ;;
  git_command) echo pull ;;
  reconcile_matching_changes) echo true ;;
  repeat.active) echo "$TEST_REPEAT" ;;
  repeat.interval) echo 1 ;;
  auto_restart|debug|git_prune) echo false ;;
 esac
}
bashio::log.info() { printf '%s\n' "$*"; }
bashio::log.warning() { printf '%s\n' "$*"; }
bashio::log.error() { printf '%s\n' "$*"; }
bashio::exit.nok() { printf '%s\n' "$*"; exit 99; }
bashio::core.check() { echo CONFIG_CHECK; }
source "$1"
setup-ssh-auth() { :; }
setup-https-auth() { :; }
cycles=0
sleep() { cycles=$((cycles + 1)); if [ "$cycles" -ge 2 ]; then exit 0; fi; }
main "$2"
"""
        repo = self.git(self.checkout, 'remote', 'get-url', remote)
        env = dict(self.env, TEST_REPEAT=repeat, TEST_REMOTE=remote, TEST_REPOSITORY=repo)
        return subprocess.run(['bash', '-c', command, 'test', str(run_script), str(self.checkout)],
                              env=env, cwd=self.checkout, capture_output=True, text=True)

    def test_loop_retries_a_conflict_without_crashing(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('unpublished\n')
        result = self.run_addon(repeat='true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count('Synchronization deferred'), 2)
        self.assertNotIn('CONFIG_CHECK', result.stdout)
        self.assertEqual(self.head(), self.old)

    def test_single_run_conflict_returns_failure(self):
        self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('unpublished\n')
        result = self.run_addon()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('CONFIG_CHECK', result.stdout)

    def test_recovery_still_validates_changed_configuration(self):
        target = self.incoming(**{'dashboard.yaml': 'published\n'})
        (self.checkout / 'dashboard.yaml').write_text('published\n')
        result = self.run_addon()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(), target)
        self.assertIn('CONFIG_CHECK', result.stdout)

    def test_configured_remote_wins_over_branch_upstream(self):
        deployment = self.root / 'deployment.git'
        self.git(self.root, 'init', '--bare', str(deployment))
        self.git(self.publisher, 'remote', 'add', 'deployment', str(deployment))
        (self.publisher / 'dashboard.yaml').write_text('deployment only\n')
        self.git(self.publisher, 'commit', '-am', 'Deployment update')
        self.git(self.publisher, 'push', 'deployment', 'main')
        self.git(self.checkout, 'remote', 'add', 'deployment', str(deployment))
        result = self.run_addon(remote='deployment')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.checkout / 'dashboard.yaml').read_text(), 'deployment only\n')
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'origin/main'), self.old)


if __name__ == '__main__':
    unittest.main()
