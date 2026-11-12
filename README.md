# pinterest-dl

**Extract direct image and video URLs from Pinterest pins, search pins, fetch board contents, and download media from Ruby or the command line.**

[![Gem Version](https://img.shields.io/gem/v/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![CI](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml/badge.svg)](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-WTFPL-blue)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.0+-red)](https://www.ruby-lang.org/)

Pinterest does not provide a public API for resolving direct media URLs from pin links, paginating public boards, or downloading pin media in bulk. `pinterest-dl` extracts direct `i.pinimg.com` and `v.pinimg.com` media URLs from pin pages and Pinterest's web resource endpoints, with zero runtime gem dependencies.

> **Network note:** Users in regions where Pinterest is restricted may need an HTTP/HTTPS proxy (`--proxy` or `config.proxy`).

## Features

- **Direct media extraction**: Resolves original or resized image URLs (`originals`, `1200x`, `736x`, `564x`, `474x`, `236x`) and highest-resolution `.mp4` video URLs from pin URLs, country subdomains, and `pin.it` short links.
- **Search and boards**: Queries Pinterest search and board/section feeds with automatic cursor pagination, duplicate pin filtering, and embedded HTML fallback.
- **Reliable downloading**: Streams files to temporary `.part` files with atomic rename on completion, validated HTTP `206 Partial Content` (`Content-Range`) and `416` resume support, `Content-Type` and magic-byte verification, configurable file-size caps, bandwidth throttling, and multi-threaded batch workers.
- **Security by default**: Blocks SSRF against loopback/private/link-local addresses, scopes cookies strictly to Pinterest domains (never leaking session cookies to CDN or third-party hosts), strips sensitive headers on cross-domain redirects, and redacts tokens/cookies from logs.
- **Isolated sessions**: Supports both global configuration (`PinterestDL.configure`) and independent per-client instances (`PinterestDL.session`).

## Installation

```bash
gem install pinterest-dl
```

Or add to your `Gemfile`:

```ruby
gem 'pinterest-dl'
```

Requires Ruby **3.0 or newer** (no external runtime dependencies).

## Quick Start

### CLI

```bash
# Print direct image or video URL
pinterest-dl image https://www.pinterest.com/pin/1234567890123456789/
pinterest-dl video https://pin.it/3vYQ7zmM5

# Download a pin image or video to disk (displays live progress bar)
pinterest-dl image https://www.pinterest.com/pin/1234567890123456789/ -o pin.jpg
pinterest-dl video https://pin.it/3vYQ7zmM5 -o video.mp4

# Inspect both image and video URLs as JSON
pinterest-dl media https://www.pinterest.com/pin/1234567890123456789/

# Search pins and download 50 results using 6 worker threads
pinterest-dl search "architectural photography" -n 50 -j 6 -o ./downloads

# Download only videos from a board, skipping existing files
pinterest-dl board https://www.pinterest.com/username/board-name/ --videos-only -n 100 -s -o ./videos
```

### Ruby Library

```ruby
require 'pinterest-dl'

# Extract direct URLs
image_url = PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/')
video_url = PinterestDL.get_video_url('https://www.pinterest.com/pin/1234567890123456789/')
media     = PinterestDL.get_media('https://www.pinterest.com/pin/1234567890123456789/', quality: :'736x')
# => { image_url: "https://i.pinimg.com/736x/...", video_url: nil }

# Download a single file
PinterestDL.download(image_url, path: 'downloads/pin.jpg', resume: true)
```

## Library Usage

### Isolated Sessions

Use `PinterestDL.session` when running multiple configurations or accounts concurrently without mutating `PinterestDL.config`:

```ruby
session = PinterestDL.session(
  cookies: File.expand_path('~/cookies.txt'),
  quality: :'1200x',
  concurrency: 6,
  max_speed: '2M'
)

pins = session.board('https://www.pinterest.com/username/board-name/', limit: 50)
report = session.download_batch(pins, dir: './downloads', collision_strategy: :rename)
```

### Search and Boards

```ruby
# Search returns an Array of pin hashes ({ id:, pin_url:, title:, description:, creator:, image_url:, video_url: })
pins = PinterestDL.search('minimalist poster', limit: 25, type: :all)
image_urls = PinterestDL.search_images('sunset', limit: 10)
video_urls = PinterestDL.search_videos('motion graphics', limit: 5)

# Fetch pins from a board or board section
board_pins   = PinterestDL.board('https://www.pinterest.com/username/board-name/', limit: 100)
section_pins = PinterestDL.board('https://www.pinterest.com/username/board-name/section-slug/', limit: 50)
```

### Batch Downloading & Collision Strategies

`download_batch` accepts an array of URLs or pin hashes and returns a `PinterestDL::DownloadReport` (which supports both method access like `report.succeeded` and Hash access like `report[:succeeded]`):

```ruby
urls = PinterestDL.search_images('mountains', limit: 40)

report = PinterestDL.download_batch(
  urls,
  dir: './downloads',
  concurrency: 4,
  resume: true,
  deduplicate: true,
  collision_strategy: :rename # :rename, :skip, or :overwrite
) do |done, total, url|
  warn "Progress: #{done}/#{total} (#{url})"
end

puts "Succeeded: #{report.succeeded.size}"
puts "Skipped:   #{report.skipped.size}"
puts "Failed:    #{report.failed.size}"
puts "Bytes:     #{report.bytes_downloaded}"
```

### Configuration

```ruby
PinterestDL.configure do |c|
  c.cookies             = File.expand_path('~/cookies.txt') # or 'sessionid=...; csrftoken=...'
  c.quality             = :originals  # :originals, :"1200x", :"736x", :"564x", :"474x", :"236x"
  c.open_timeout        = 10          # seconds
  c.read_timeout        = 20          # seconds
  c.write_timeout       = 20          # seconds
  c.max_retries         = 3           # retries on transient network / 429 / 5xx errors
  c.retry_wait          = 1.0         # base backoff in seconds
  c.max_retry_wait      = 30.0        # maximum backoff cap in seconds
  c.retry_jitter        = 0.25        # random jitter ratio added to backoff
  c.rate_limit_interval = 0.5         # minimum seconds between requests
  c.concurrency         = 4           # worker threads for download_batch
  c.overwrite           = true        # overwrite existing files when collision_strategy is not set
  c.resume              = true        # resume partial .part files via HTTP Range
  c.deduplicate         = true        # skip duplicate URLs within a batch
  c.collision_strategy  = :rename     # :rename, :skip, or :overwrite
  c.max_file_size       = 500 * 1024 * 1024 # 500 MB cap per file
  c.max_speed           = nil         # e.g. '500K' or '2M' per worker
  c.verify_content_type = true        # reject HTML/JSON error responses and empty payloads
  c.proxy               = nil         # HTTP/HTTPS proxy URL (defaults to HTTPS_PROXY / HTTP_PROXY)
  c.max_cache_entries   = 256         # LRU cache size for GET requests
end
```

## CLI Reference

```text
Usage:
  pinterest-dl image URL [-q QUALITY] [-o PATH] [options]
  pinterest-dl video URL [-o PATH] [options]
  pinterest-dl media URL [-q QUALITY] [options]
  pinterest-dl search QUERY [-n LIMIT] [-t TYPE] [-q QUALITY] [-j JOBS] [-o DIR] [options]
  pinterest-dl board URL [-n LIMIT] [-t TYPE] [-q QUALITY] [-j JOBS] [-o DIR] [options]

Options:
  -o, --output PATH          File or directory to save downloaded media (omit to print direct URL)
  -n, --limit N              Max number of results or files to download (default 25)
  -t, --type TYPE            Filter media type: all, image, video, pin (default all)
      --images-only          Shortcut for --type image
      --videos-only          Shortcut for --type video
  -q, --quality Q            Image quality: originals, 1200x, 736x, 564x, 474x, 236x
  -c, --cookies STR|FILE     Cookie header string or Netscape cookies.txt file path
  -j, --jobs N               Parallel download workers for batch downloads (default 4)
  -s, --skip-existing        Skip files that already exist on disk
      --resume               Resume partially downloaded .part files (default true)
      --no-resume            Restart interrupted downloads from scratch
      --max-size BYTES       Maximum allowed file size (e.g. 100M, 500M)
      --max-speed RATE       Throttle download speed per worker (e.g. 500K, 2M)
      --format FMT           Output report format: text, json, csv, quiet (default text)
      --json                 Output results and summary in JSON format
      --no-progress          Disable live progress bar output
      --non-interactive      Run without interactive terminal animations or prompts
      --proxy URL            HTTP/HTTPS proxy URL
      --timeout SEC          Network read/open timeout in seconds
      --retries N            Max retries on transient failures (default 3)
  -v, --verbose              Enable debug logging
      --version              Print version and exit
  -h, --help                 Show this help
```

## Error Handling

All library exceptions inherit from `PinterestDL::Error < StandardError` and expose `#url`, `#status_code`, and `#cause_error`:

| Exception Class | Cause |
| :--- | :--- |
| `PinterestDL::NotFoundError` | Pin, board, section, or media URL was not found (`404` or missing media). |
| `PinterestDL::AuthenticationError` | HTTP `401` — authentication cookies are required. |
| `PinterestDL::ForbiddenError` | HTTP `403` — request blocked by Pinterest (invalid CSRF/cookies or IP restriction). |
| `PinterestDL::RateLimitError` | HTTP `429` — rate limited (`#retry_after` contains server hint when present). |
| `PinterestDL::RangeNotSatisfiableError` | HTTP `416` — requested byte range is outside the remote resource size. |
| `PinterestDL::TimeoutError` | Connection, read, or write timeout after retries. |
| `PinterestDL::ConnectionError` | Socket reset, DNS failure, or dropped connection. |
| `PinterestDL::RedirectError` | Redirect loop, missing `Location`, or untrusted cross-domain redirect target. |
| `PinterestDL::InvalidURLError` / `SSRFError` | Malformed URL, non-Pinterest host, embedded credentials, or blocked private/loopback IP. |
| `PinterestDL::InvalidResponseError` | Malformed JSON or invalid HTTP `206` `Content-Range` header. |
| `PinterestDL::FileTooLargeError` | Remote `Content-Length` or streamed bytes exceeded `max_file_size`. |
| `PinterestDL::IncompleteDownloadError` | Stream ended before receiving the declared `Content-Length` / `Content-Range`. |
| `PinterestDL::InvalidMediaError` | Server returned `text/html` / `application/json` instead of media. |
| `PinterestDL::DiskSpaceError` | Insufficient disk space (`ENOSPC`) or non-writable target directory (`EACCES`/`EROFS`). |

## Development & Testing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development instructions.

```bash
bundle install
bundle exec rake test
bundle exec rake rubocop
```

## License

[WTFPL](LICENSE) — [monji024](https://github.com/monji024)