# pinterest-dl

**Get direct image/video URLs from Pinterest, search pins, fetch board contents, and download media — as a Ruby library or a CLI.**

[![Gem Version](https://img.shields.io/gem/v/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![Gem Downloads](https://img.shields.io/gem/dt/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![CI](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml/badge.svg)](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-WTFPL-blue)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-2.7+-red)](https://www.ruby-lang.org/)

<img src="https://img.icons8.com/color/96/000000/pinterest--v1.png" width="80">

> **Note:** Users in some regions (e.g. Iran) may need a fu*king VPN to reach Pinterest.  
> (Yeah, because even in 2026 Pinterest still gives you the middle finger on clean APIs.)

Pinterest doesn't give you a clean, official API for getting a direct media URL out of a pin, walking a board, or downloading a batch of images. `pinterest-dl` does that: point it at a pin, a search query, or a board, and get back real `i.pinimg.com` / `v.pinimg.com` URLs — or the fucking files themselves, already saved to disk.

## What it does

- Pulls the **direct image or video URL** out of a single pin page (including `pin.it` short links and country domains).
- **Searches** Pinterest and returns pin metadata (id, url, title, description, creator, image/video URL), with automatic pagination.
- Fetches all pins from a **board** (or a specific board section).
- **Downloads** a URL or a whole batch in parallel (multi-threaded, written to `.part` files first so interrupted runs don't leave broken files on disk).
- Supports **authenticated requests** via raw cookie strings or a Netscape `cookies.txt` file, for boards/pins that require a logged-in session.
- Raises **specific, catchable exceptions** (`NotFoundError`, `RateLimitError`, `NetworkError`, ...) instead of returning `nil` or printing to stdout.
- Ships a **CLI** (`pinterest-dl`) for one-off use from the shell.

## Installation

```bash
gem install pinterest-dl
```

Or add it to your Gemfile:

```ruby
gem 'pinterest-dl'
```

## Quick start

```ruby
require 'pinterest-dl'

# Direct image URL
PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/')
# => "https://i.pinimg.com/originals/aa/bb/cc/aabbcc...jpg"

# Direct video URL (raises PinterestDL::NotFoundError if the pin has no video)
PinterestDL.get_video_url('https://www.pinterest.com/pin/1234567890123456789/')
# => "https://v.pinimg.com/videos/mc/720p/aa/bb/cc/aabbcc....mp4"

# Download it
PinterestDL.download(
  PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/'),
  path: 'downloads/pin.jpg'
)
```

## Usage

### Get image / video URLs

```ruby
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/')

# Pick a specific size bucket
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/', quality: :"736x")
# quality can be :originals, :"1200x", :"736x", :"564x", :"474x", :"236x"

url = PinterestDL.get_video_url('https://www.pinterest.com/pin/example/')

# Both at once
media = PinterestDL.get_media('https://www.pinterest.com/pin/example/')
# => { image_url: "https://i.pinimg.com/...", video_url: nil }
```

### Search

```ruby
results = PinterestDL.search('nature landscape', limit: 10)
# => [{ id: "...", pin_url: "...", title: "...", description: "...", creator: "...", image_url: "...", video_url: nil }, ...]

# Page count scales with limit, or cap it yourself with pages:
results = PinterestDL.search('nature landscape', limit: 150)
video_pins = PinterestDL.search('motion graphics', limit: 20, type: :video)

images = PinterestDL.search_images('sunset', limit: 5)
# => ["https://i.pinimg.com/originals/...", ...]

videos = PinterestDL.search_videos('tutorial', limit: 3)
# => ["https://v.pinimg.com/videos/...", ...]

json_results = PinterestDL.search_json('anime art', limit: 20)
```

### Boards & sections

```ruby
# All pins on a board
pins = PinterestDL.board('https://www.pinterest.com/username/board-name/', limit: 100)

# Only videos from a board
videos = PinterestDL.board('https://www.pinterest.com/username/board-name/', limit: 50, type: :video)

# A specific section within a board
pins = PinterestDL.board('https://www.pinterest.com/username/board-name/section-slug/', limit: 50)
```

### Downloading

```ruby
# Single file
PinterestDL.download('https://i.pinimg.com/originals/aa/bb/cc/img.jpg', path: 'out/img.jpg')

# Skip if already on disk
PinterestDL.download(url, path: 'out/img.jpg', overwrite: false)

# Batch download (returns { succeeded: [...], failed: [{ url:, error: }, ...], skipped: [...] })
urls = PinterestDL.search_images('mountains', limit: 40)
result = PinterestDL.download_batch(urls, dir: './downloads', concurrency: 6, overwrite: false)

# With progress reporting
bar = PinterestDL::ProgressBar.new(total: urls.size, out: $stderr)
PinterestDL.download_batch(urls, dir: './downloads') do |done, total, url|
  bar.update(done)
end
```

### Cookies / authenticated sessions

Some boards and pins require a logged-in session to view. Pass your browser's Pinterest cookies (either a raw string or a Netscape `cookies.txt` path) through global configuration:

```ruby
PinterestDL.configure do |c|
  c.cookies    = 'sessionid=...; csrftoken=...' # yeah, steal your own fucking session if you have to
  # c.cookies  = File.expand_path('~/cookies.txt')
  c.user_agent = 'Mozilla/5.0 ...' # optional override
end
```

### Other configuration

```ruby
PinterestDL.configure do |c|
  c.open_timeout        = 10   # seconds, connection open timeout
  c.read_timeout        = 20   # seconds, response read timeout
  c.write_timeout       = 20   # seconds, request write timeout

# step-1
