# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

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
- The gem no longer prints anythign on `require`.

## [1.0.3]

- Initial public release: `get_image_url`, `get_video_url`, `search`,
  `search_json`, `search_images`, `search_videos`.
