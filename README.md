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

# step-0
