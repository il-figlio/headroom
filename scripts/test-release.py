"""Offline publish preflight checks. No subprocesses or GitHub requests."""
import argparse
import contextlib
import io
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


HEAD = 'a' * 40
TAG_OBJECT = 'b' * 40


class PublishChecks(unittest.TestCase):
    def setUp(self):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        out = pathlib.Path(stack.enter_context(tempfile.TemporaryDirectory(dir=release.ROOT)))
        paths = {name: out / getattr(release, name).name for name in ('ZIP', 'DMG', 'FEED', 'SUMS')}
        stack.enter_context(patch.multiple(release, **paths))
        release.ZIP.write_bytes(b'zip fixture')
        release.DMG.write_bytes(b'dmg fixture')
        release.FEED.write_text('not a signed appcast')
        release.write_sums()
        self.notes = out / 'notes.md'
        self.notes.write_text('Notes fixture.')
        self.pushed = {'type': 'tag', 'sha': TAG_OBJECT}
        self.commit = HEAD
        self.valid_tag_signature = True
        self.mutate = stack.enter_context(patch.object(release, 'gh_release'))
        self.draft = {'draft': True, 'html_url': 'draft fixture'}
        self.find_release = stack.enter_context(patch.object(release, 'find_release', return_value=self.draft))
        stack.enter_context(patch.object(release, 'run', side_effect=self.command))
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.stderr = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))

    def command(self, *args, **kwargs):
        if args == ('gh', 'api', f'repos/{release.REPO}/git/ref/tags/{release.TAG}'):
            if self.pushed is None:
                return subprocess.CompletedProcess(args, 1, '', 'gh: Not Found (HTTP 404)')
            return subprocess.CompletedProcess(args, 0, json.dumps({'object': self.pushed}), '')
        if args == ('git', 'verify-tag', TAG_OBJECT):
            return subprocess.CompletedProcess(args, 0 if self.valid_tag_signature else 1)
        git = {
            ('rev-parse', 'HEAD'): HEAD,
            ('rev-parse', '--verify', '--quiet', f'refs/tags/{release.TAG}'): TAG_OBJECT,
            ('rev-parse', '--verify', TAG_OBJECT + '^{commit}'): self.commit,
        }
        if args[0] == 'git' and args[1:] in git:
            return subprocess.CompletedProcess(args, 0, git[args[1:]] + '\n', '')
        if args == ('codesign', '--verify', '--strict', release.DMG):
            return subprocess.CompletedProcess(args, 0)
        if args == ('codesign', '-dv', '--verbose=2', release.DMG):
            return subprocess.CompletedProcess(args, 0, '', 'Signature=adhoc')
        raise AssertionError(f'Unexpected subprocess: {args}')

    def publish(self, verify_tag=True):
        release.publish(argparse.Namespace(notes=self.notes, verify_tag=verify_tag))

    def refuses(self, message, verify_tag=True):
        with self.assertRaisesRegex(release.Failure, message):
            self.publish(verify_tag)
        self.mutate.assert_not_called()

    def test_tag_points_to_another_commit(self):
        self.commit = 'c' * 40
        for strict in (True, False):
            with self.subTest(verify_tag=strict):
                self.refuses('not HEAD', strict)

    def test_existing_tag_must_be_signed_and_match_local(self):
        self.pushed['type'] = 'commit'
        self.refuses('lightweight tag', verify_tag=False)
        self.pushed = {'type': 'tag', 'sha': 'c' * 40}
        self.refuses('not the local tag')
        self.pushed['sha'] = TAG_OBJECT
        self.valid_tag_signature = False
        self.refuses('does not accept a signature')

    def test_missing_tag_requires_review_mode(self):
        self.pushed = None
        self.refuses('No tag .* exists on GitHub')
        with patch.object(release, 'check_artifacts'):
            self.publish(verify_tag=False)
        self.assertEqual(self.mutate.call_args_list[0].args,
                         ('edit', release.TAG, '--target', HEAD, '--notes-file', self.notes))
        self.assertIn('DO NOT PUBLISH', self.stderr.getvalue())

    def test_invalid_checksums(self):
        release.SUMS.write_text(release.SUMS.read_text().splitlines()[0] + '\n')
        self.refuses('SHA256SUMS')
        release.write_sums()
        release.DMG.write_bytes(b'changed since checksumming')
        self.refuses('SHA256SUMS')

    def test_missing_or_invalid_appcast(self):
        self.refuses('no valid embedded Sparkle signature')
        release.FEED.unlink()
        self.refuses('run appcast first')

    def test_appcast_archive_signature_must_match_zip(self):
        # Bypass cryptography only; exercise actual feed parsing and ZIP validation.
        signed = (f'<rss xmlns:sparkle="{release.SPARKLE_NS}"><channel><item>'
                  f'<sparkle:version>{release.BUILD}</sparkle:version>'
                  f'<sparkle:shortVersionString>{release.VERSION}</sparkle:shortVersionString>'
                  f'<enclosure url="{release.PUBLIC_URL}" length="{release.ZIP.stat().st_size}" '
                  'sparkle:installationType="application" sparkle:edSignature="AAAA"/>'
                  '</item></channel></rss>').encode()
        release.FEED.write_bytes(signed + f'<!-- sparkle-signatures: edSignature: AAAA length: {len(signed)} -->'.encode())
        with patch.object(release.ed25519, 'verify', side_effect=[True, False]):
            self.refuses('Enclosure edSignature does not verify against the ZIP')

    def test_non_distribution_dmg(self):
        with patch.object(release, 'check_feed'):
            self.refuses('not Developer ID signed')

    def test_verified_tag_draft_is_created_only_after_preflight(self):
        self.find_release.side_effect = [None, self.draft]
        with patch.object(release, 'check_artifacts') as preflight:
            preflight.side_effect = lambda *args, **kwargs: self.mutate.assert_not_called()
            self.publish()
        self.assertTrue(preflight.call_args.kwargs['distribution'])
        self.assertEqual(self.mutate.call_args_list[0].args[:4], ('create', release.TAG, '--draft', '--verify-tag'))
        self.assertEqual([call.args[0] for call in self.mutate.call_args_list], ['create', 'upload', 'upload'])

    def test_verified_tag_retargets_an_existing_draft(self):
        with patch.object(release, 'check_artifacts'):
            self.publish()
        self.assertEqual(self.mutate.call_args_list[0].args,
                         ('edit', release.TAG, '--target', HEAD, '--notes-file', self.notes))


if __name__ == '__main__':
    unittest.main()
