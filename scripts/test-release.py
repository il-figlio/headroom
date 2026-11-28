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
        self.draft = {'draft': True, 'html_url': 'draft fixture',
                      'assets': [{'name': path.name} for path in (release.ZIP, release.DMG, release.SUMS, release.FEED)]}
        self.find_release = stack.enter_context(patch.object(release, 'find_release', return_value=self.draft))
        stack.enter_context(patch.object(release, 'run', side_effect=self.command))
        self.stdout = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.stderr = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))

    def command(self, *args, **kwargs):
        if args == ('gh', 'api', f'repos/{release.REPO}/git/ref/tags/{release.TAG}'):
            if self.pushed is None:
                return subprocess.CompletedProcess(args, 1, '', 'gh: Not Found (HTTP 404)')
            if isinstance(self.pushed, list):
                return subprocess.CompletedProcess(args, 0, json.dumps(self.pushed), '')
            return subprocess.CompletedProcess(args, 0, json.dumps({'ref': f'refs/tags/{release.TAG}', 'object': self.pushed}), '')
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
                         ('edit', release.TAG, '--target', HEAD, '--title', release.TITLE, '--notes-file', self.notes))
        self.assertIn('DO NOT PUBLISH', self.stderr.getvalue())

    def test_prefix_match_list_counts_as_missing_tag(self):
        # git/ref/tags/<tag> may answer a prefix match with a JSON list.
        self.pushed = [{'ref': f'refs/tags/{release.TAG}-rc1', 'object': {'type': 'tag', 'sha': TAG_OBJECT}}]
        self.refuses('No tag .* exists on GitHub')
        with patch.object(release, 'check_artifacts'):
            self.publish(verify_tag=False)
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
        self.assertEqual([call.args[0] for call in self.mutate.call_args_list], ['create', 'upload'])
        self.assertIn('--title', self.mutate.call_args_list[0].args)

    def test_verified_tag_retargets_an_existing_draft(self):
        with patch.object(release, 'check_artifacts'):
            self.publish()
        self.assertEqual(self.mutate.call_args_list[0].args,
                         ('edit', release.TAG, '--target', HEAD, '--title', release.TITLE, '--notes-file', self.notes))
        self.assertIn('--draft=false --latest --verify-tag', self.stdout.getvalue())

    def test_all_assets_are_uploaded_in_one_call(self):
        with patch.object(release, 'check_artifacts'):
            self.publish()
        uploads = [call.args for call in self.mutate.call_args_list if call.args[0] == 'upload']
        self.assertEqual(uploads, [('upload', release.TAG, release.ZIP, release.DMG, release.SUMS, release.FEED, '--clobber')])

    def test_leftover_draft_asset_fails(self):
        self.draft['assets'].append({'name': 'Headroom-0.8.0.dmg'})
        with patch.object(release, 'check_artifacts'):
            with self.assertRaisesRegex(release.Failure, 'unexpected: Headroom-0.8.0.dmg'):
                self.publish()
        self.draft['assets'] = self.draft['assets'][:2]
        with patch.object(release, 'check_artifacts'):
            with self.assertRaisesRegex(release.Failure, 'missing: '):
                self.publish()


class PromoteChecks(unittest.TestCase):
    def setUp(self):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(release.urllib.request, 'urlretrieve', side_effect=AssertionError('urlretrieve')))
        self.check_feed = stack.enter_context(patch.object(release, 'check_feed'))
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        # promote writes ROOT/appcast.xml on success; every test here must fail first.
        stack.enter_context(patch.object(release.pathlib.Path, 'write_bytes', side_effect=AssertionError('write_bytes')))

    def promote(self):
        release.promote(argparse.Namespace(from_release=True, no_download_check=True))

    def test_feed_download_is_capped(self):
        def oversized(url, destination, limit):
            destination.write_text('x' * (limit + 1))
        with patch.object(release, 'download', side_effect=oversized) as download:
            with self.assertRaisesRegex(release.Failure, 'larger than'):
                self.promote()
        url, _, limit = download.call_args.args
        self.assertEqual(url, f'https://github.com/{release.REPO}/releases/download/{release.TAG}/appcast.xml')
        self.assertEqual(limit, release.FEED_LIMIT)
        self.check_feed.assert_not_called()

    def test_feed_download_error_is_a_failure(self):
        with patch.object(release, 'download', side_effect=OSError('HTTP Error 404')):
            with self.assertRaisesRegex(release.Failure, 'not publicly downloadable'):
                self.promote()


if __name__ == '__main__':
    unittest.main()
