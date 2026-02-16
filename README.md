# pinterest-dl

Get direct image and video URLs from Pinterest:)

![Demo](./test.gif)

## Installation

```ruby
gem install pinterest-dl
```

## Usage

```ruby
require 'pinterest-dl'
```

### Get image url

```ruby
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/')
# => "https://i.pinimg.com/originals/8e/2a/..."
```

###  Get video url

```ruby
url = PinterestDL.get_video_url('https://www.pinterest.com/pin/example/')
# => "https://v.pinimg.com/videos/..."
```

##  Links

- [RubyGem](https://rubygems.org/gems/pinterest-dl)
- [GitHub](https://github.com/monji024/pinterest-dl)

##  License

MIT © [monji024](https://github.com/monji024)
