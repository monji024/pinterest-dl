# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [2.3.0]

### Added
- `download_batch` now runs downloads in parallel using a thread pool (default 4 workers, configurable via `config.concurrency` or `-j/--jobs` on the CLI).
- `cookies` in `PinterestDL.configure` (and `-c/--cookies` on the CLI) now accepts a path to a Netscape `cookies.txt` file in addition to a raw `key=val; ...` cookie string.
- Added `1200x` and `564x` image quality buckets alongside `originals`, `736x`, `474x`, and `236x`.
- `overwrite: false` on `download` / `download_batch` and `-s/--skip-existing` on the CLI to skip files that are already on disk when resuming a big board or search dump.
- HTTP/HTTPS proxy support via `config.proxy` (defaults to `HTTPS_PROXY` / `HTTP_PROXY` env vars) and `--proxy` on the CLI, plus `--timeout` and `--retries` flags.
- `Client#stream_get` for streaming large video responses straight to disk instead of buffering the whole file in memory.

### Fixed
- `search` and `board` had a hardcoded default of 5 and 10 pages, so passing `-n 200` on the CLI silently stopped around ~125 pins. Page count now scales automatically with `limit` unless `pages:` is passed explicitly.
- Downloads now write to a temporary `.part` file first and atomically rename on completion, so a dropped connection or `Ctrl-C` mid-download doesn't leave half-written corrupt files behind.
- `Client` only retried socket-level exceptions (`SocketError`, `Timeout::Error`, etc.) and immediately blew up on HTTP 429 or 502/503/504. Transient HTTP status codes are now retried too, respecting `Retry-After` when Pinterest sends one.
- `Extractors::Image` missed numbered CDN hosts like `i0.pinimg.com` and `i1.pinimg.com` and didn't rewrite non-standard dimension buckets (e.g. `600x315`) when switching quality.
- `Client` cache and cookie jar access are now guarded by a mutex so concurrent workers don't race each other, rate-limit throttling uses `CLOCK_MONOTONIC` instead of wall-clock `Time.now`, and the in-memory cache is capped (`max_cache_entries`, default 256) so long-running scripts don't leak memory.
- Logger and `ProgressBar` output on the CLI now go to `stderr` instead of `stdout`, so piping `pinterest-dl search ... | jq .` doesn't get polluted by warnings or progress bars.
- `Ctrl-C` (`SIGINT`) in the CLI now exits cleanly with code 130 instead of dumping a Ruby backtrace.

## [2.2.0]

### Fixed
- `Board` and `Search` API calls were getting rejected on some endpoints because `X-Pinterest-Source-Url` and `X-Pinterest-AppState` headers were missing. Both are sent now, board slugs are matched case-insensitively, duplicate pins across pages are filtered out, `config.quality` is applied to returned URLs, and both fall back to SSR pins embedded in the HTML if the API feed comes back empty.
- `Search` was hitting the search HTML page on every single pagination step to grab a session; it now establishes the session once per search call and also handles responses where `data` is a flat array instead of `{ results: [...] }`.
- `PinData` now reads `<script data-relay-response="true">` blocks in addition to `__PWS_*__` tags, and picks the best available image when `orig` isn't present.
- `Client` normalizes country subdomains (`de.pinterest.com`, `fr.pinterest.com`, etc.) in its cookie jar, guards `Client#cookie` when `@last_url` is nil, and raises `AuthenticationError` on HTTP 401.
- `get_media` now falls back to `PinResource` when the initial pin HTML doesn't have both media URLs.
- CLI: wired up `-v/--verbose`, `--version`, the `media` subcommand, and made `-q/--quality` apply globally.

## [2.1.5]

### Fixed
- Pin URLs on country domains (e.g. `de.pinterest.com/pin/...`) didn't download
  while `pin.it` links did. Pin URLs are now normalised to
  `www.pinterest.com/pin/ID/`, and the HTTP client follows redirects itself
  (max 5) with a small cookie jar, so a redirect loop can no longer happen.
- `Client#raw_get` returned the first redirect response instead of the final
  one, which lost the session cookie / CSRF token.
- Pin extraction could pick a related pin instead of the pin you asked for.
  The pin is now matched by its id.
- Video pins returned "No video found". The best `.mp4` is picked now (not just
  the first format, which could be an `.m3u8`), story pins are supported, and
  `og:video` meta tags are read in any attribute order.
- `video` worked only some of the time: Pinterest sometimes serves a lighter
  page without the video data. Now every `__PWS_*__` data block of the page is
  read, then the pin is asked from the `PinResource` API (with the
  `X-Pinterest-PWS-Handler` header Pinterest needs, otherwise it answers 403),
  and the page is fetched fresh up to 3 times before giving up. The "this is an
  image" hint only shows when Pinterest really returned an image pin.
- `board` reads the board id from the page first and only asks the API when it
  isn't there. Story modules ("Related interests") are no longer treated as pins.
- `board` never worked: Pinterest needs the real board id, we sent an empty
  one. The id is now looked up first, the session is created once instead of
  once per page, links with `?invite_code=...` are parsed correctly, and
  `pin.it` links work. Sections use `BoardSectionPinsResource`.

### Added
- `--type all|image|video|pin` for `search` and `board`
  (`PinterestDL.search(..., type: :video)`, `PinterestDL.board(..., type: :image)`).

# step-0
