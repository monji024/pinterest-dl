<div align="center">

# pinterest-dl

---

[![Gem Downloads](https://img.shields.io/gem/dt/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-2.5+-red)](https://www.ruby-lang.org/)

<img src="https://img.icons8.com/color/96/000000/pinterest--v1.png" width="80">

</div>

---

Get direct image and video URLs from Pinterest.

![Demo](https://github.com/monji024/pinterest-dl/raw/main/test.gif)

> **Note:** Users in Iran may need a VPN to access Pinterest.

## Installation

```bash
gem install pinterest-dl
```

## Usage

```ruby
require 'pinterest-dl'
```

### Get Image URL

```ruby
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/')
```

### Get Video URL

```ruby
url = PinterestDL.get_video_url('https://www.pinterest.com/pin/example/')
```

### Search Pins

```ruby
# Search for pins with a specific query
results = PinterestDL.search('nature landscape', limit: 10)

# Returns an array of pin objects with:
# id, pin_url, title, description, image_url, video_url

# Get only image URLs from search results
images = PinterestDL.search_images('sunset', limit: 5)
# => ["https://i.pinimg.com/originals/...", ...]

# Get only video URLs from search results
videos = PinterestDL.search_videos('tutorial', limit: 3)
# => ["https://v.pinimg.com/videos/...", ...]

# Get search results as JSON
json_results = PinterestDL.search_json('anime art', limit: 20)
# => Returns formatted JSON string
```

## Links

- [RubyGems](https://rubygems.org/gems/pinterest-dl)
- [GitHub](https://github.com/monji024/pinterest-dl)

## License

MIT © [monji024](https://github.com/monji024)