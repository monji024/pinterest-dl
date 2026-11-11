# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [2.4.0]

### Security
- Added `PinterestDL::Security` with strict URL/host validation, SSRF protection against private, loopback, link-local, and metadata IP ranges (`SSRFError`), and rejection of embedded URL credentials.
- Added `PinterestDL::CookieJar` preserving `Domain`, `Path`, `Secure`, `HttpOnly`, and `Expires`/`Max-Age` attributes and strictly preventing cookies from being sent to CDN (`*.pinimg.com`), shortener (`pin.it`), or external hosts.
- Cross-domain redirects are now validated against trusted hosts (`RedirectError`) and strip sensitive headers (`Cookie`, `Authorization`, `X-CSRFToken`) when crossing security domains.
- Added `PinterestDL::MediaValidator` to verify HTTP `Content-Type` headers and binary file signatures (JPEG, PNG, GIF, WebP, MP4, WebM) and reject HTML/JSON error pages disguised as media (`InvalidMediaError`).
- Enforced configurable maximum download file size (`config.max_file_size`, default 500 MB, or `--max-size` on the CLI) with `FileTooLargeError`.
- Logger output automatically redacts cookies, CSRF tokens, session IDs, and proxy passwords.

### Added
- `PinterestDL::Session` (`PinterestDL.session`) for fully isolated per-client configuration and cookie jars without global state interference.
- `PinterestDL::Transport` layer with exponential backoff and random jitter (`retry_jitter`, `max_retry_wait`), plus full support for both integer and HTTP-date `Retry-After` headers.
- `PinterestDL::Paginator` for unified cursor/bookmark pagination across `Search` and `Board`, with duplicate bookmark cycle detection and `Enumerable` support.
- `PinterestDL::Pin` and `PinterestDL::DownloadReport` models supporting both object-oriented methods and Hash `[]`/`dig` access.
- Resumable downloads (`Range: bytes=N-` with HTTP `206 Partial Content`) via `resume: true` and `--resume`/`--no-resume`.
- Download speed throttling (`max_speed:` / `--max-speed`, e.g. `500K`, `2M`), batch URL deduplication (`deduplicate: true`), smart filename collision handling (`collision_strategy: :rename`), and disk space / write-permission error handling (`DiskSpaceError`).
- Live byte-level `ProgressBar` showing percentage, received/total bytes, download speed, ETA, and media type badge (`[IMAGE]` / `[VIDEO]`), with `--no-progress` and `--non-interactive` flags.
- Extracted CLI logic into `PinterestDL::CLI` (`lib/pinterest_dl/cli.rb`) with `--format text|json|csv|quiet`, `--json`, `--images-only`, `--videos-only`, and actionable error hints.
- Expanded error hierarchy: `ForbiddenError` (distinct from `RateLimitError`), `TimeoutError`, `ConnectionError`, `SSLError`, `RedirectError`, `SSRFError`, `InvalidResponseError`, `FileTooLargeError`, `IncompleteDownloadError`, `InvalidMediaError`, and `DiskSpaceError`.

### Fixed
- `Extractors::PinData.best_image_url` now ranks image variants by resolution area and bucket priority instead of relying on hash insertion order.
- Added support for `__NEXT_DATA__`, `window.__INITIAL_STATE__`, `srcset`, and `<video>`/`<source>` fallbacks when extracting media from HTML.
- Fixed race conditions and thread exception propagation in `Downloader#download_batch`, and verified `Content-Length` to detect truncated downloads (`IncompleteDownloadError`).

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
  `pin` prints the pin links (saved to `pins.txt` with `-o`).
- With `-o` and type `all`, video pins are now saved as videos, not thumbnails.

## [2.0.3]

### Fixed
- **`PinterestDL::Board` was broken.** `lib/pinterest_dl/board.rb` accidentally
  defined `class Search` instead of `class Board` (with a full copy of the old
  search logic), so it silently collided with `PinterestDL::Search` at load
  time and `PinterestDL.board(...)` never worked correctly. Restored the
  correct `Board` class backed by Pinterest's `BoardFeedResource`.
- `PinterestDL.board` requests were missing a session cookie and CSRF token,
  which Pinterest's internal resource API requires — every board request
  came back as HTTP 403. `Board` now loads the board page first to obtain
  a session cookie + CSRF token before calling the resource API, the same
  way `Search` already did.
- `pin.it/...` short links were rejected by `get_image_url` / `get_video_url` /
  `get_media` even though Pinterest itself redirects them to a normal pin
  page. `PIN_URL_PATTERN` now accepts `pin.it/...` links too.
- The raw-HTML fallback regex used to find an image when no `og:image` or
  JSON-LD tag was present could "bleed" past the actual image URL into
  trailing inline CSS (e.g. `...img.png)}._YsBbF{border:0...`), producing a
  garbage, unusable URL. The regex now requires a real image extension and
  only matches valid URL characters, so it stops exactly at the image URL.
- Image/video extraction now tries Pinterest's embedded page-state JSON
  (`<script id="__PWS_DATA__">`) first via a new `Extractors::PinData`
  module, which is far more reliable than scraping meta tags/regex and is
  immune to the CSS-bleed issue above; the old scraping strategies remain as
  a fallback if a page doesn't embed that data.

## [2.0.0]

### Added
- `PinterestDL.download` / `PinterestDL.download_batch` for real file downloads,
  the latter with per-file progress callbacks and a `PinterestDL::ProgressBar` helper.
- `PinterestDL.board` for fetching pins from a board or board section, with pagination.
- `PinterestDL.configure` for global settings: cookies/session, user agent,
  timeouts, retry count, request rate limiting, and default image quality.
- `PinterestDL.get_media` to fetch image + video URLs for a pin in one request.
- Pagination support in `PinterestDL.search` (`pages:` option).
- `creator` field on pin metadata returned by `search` and `board`.
- Meaningful exception hierarchy under `PinterestDL::Error` (`NetworkError`,
  `NotFoundError`, `RateLimitError`, `AuthenticationError`, `InvalidURLError`,
  `DownloadError`) replacing silent `nil` returns and `puts`-based error reporting.
- Real CLI: `pinterest-dl image|video|search|board ...`.
- Configurable timeouts and retry/backoff on all HTTP requests.
- Small in-memory response cache and optional request rate limiting.
- Test suite (Minitest) and GitHub Actions CI matrix (Ruby 3.0–3.3).
- RuboCop configuration.

### Changed
- User-Agent updated to a current Chrome UA string.
- All `puts` debug/status output removed from library code in favor of a
  configurable `Logger` (`PinterestDL.config.logger`).
- Internals reorganized into `lib/pinterest_dl/{client,configuration,errors,
  extractors,search,board,downloader,progress_bar,api}.rb`; `PinterestDL::VERSION`
  is now the single source of truth for the gem version.

### Fixed
- The gem no longer prints anything on `require`.

## [1.0.3]
- Initial public release: `get_image_url`, `get_video_url`, `search`,
  `search_json`, `search_images`, `search_videos`.