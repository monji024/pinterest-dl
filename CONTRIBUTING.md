# Contributing to pinterest-dl

Thank you for your interest in improving `pinterest-dl`.

## Development Setup

`pinterest-dl` targets Ruby 3.0+ and has zero runtime gem dependencies.

```bash
git clone https://github.com/monji024/pinterest-dl.git
cd pinterest-dl
bundle install
```

## Running Tests and Linters

Run the Minitest suite and RuboCop before submitting changes:

```bash
bundle exec rake test      # Run unit and regression tests
bundle exec rake coverage  # Run tests with SimpleCov branch coverage
bundle exec rake rubocop   # Run RuboCop style and lint checks
bundle exec rake           # Run both test and rubocop tasks
```

## Architecture Overview

- `lib/pinterest_dl/api.rb` — Top-level module methods (`get_image_url`, `get_video_url`, `get_media`, `search`, `board`, `download`, `download_batch`, `session`).
- `lib/pinterest_dl/session.rb` — Isolated client session (`PinterestDL::Session`) with independent configuration and cookie jar.
- `lib/pinterest_dl/transport.rb` — Low-level HTTP transport handling retries, exponential backoff with jitter, `Retry-After`, redirects, and Pinterest resource API calls.
- `lib/pinterest_dl/security.rb` — URL validation, SSRF protection against private/loopback IP ranges, redirect target verification, and log redaction.
- `lib/pinterest_dl/cookie_jar.rb` — Domain- and path-scoped cookie storage that prevents leaking session cookies to CDN or external hosts.
- `lib/pinterest_dl/downloader.rb` — Single-file and multi-threaded batch downloader with HTTP `206` (`Content-Range`) / `416` resume handling, `max_file_size` enforcement, content-type and magic-byte verification, bandwidth throttling, and collision strategies (`:rename`, `:skip`, `:overwrite`).
- `lib/pinterest_dl/paginator.rb` — Cursor/bookmark pagination engine shared by `Search` and `Board`.
- `lib/pinterest_dl/extractors/` — HTML and embedded JSON (`__PWS_DATA__`, Relay, Next.js, JSON-LD, OpenGraph) media extractors.
- `lib/pinterest_dl/cli.rb` — Command-line interface implementation invoked by `bin/pinterest-dl`.

## Pull Request Guidelines

1. Keep changes focused and backward-compatible whenever possible.
2. Add regression tests in `test/pinterest_dl/` for bug fixes or new behavior.
3. Ensure `bundle exec rake` passes without offenses or test failures.
4. Do not commit built `*.gem` archives, credentials, or real session cookies.
