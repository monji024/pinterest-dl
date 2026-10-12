# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [2.0.5]

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
- The gem no longer prints anythign on `require`.

## [1.0.3]

- Initial public release: `get_image_url`, `get_video_url`, `search`,
  `search_json`, `search_images`, `search_videos`.
