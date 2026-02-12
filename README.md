# pinterest-dl

Get direct image and video URLs from Pinterest:)



```ruby
gem install pinterest-dl

```

## Usage

```ruby
require 'pinterest-dl'
```


# Get image url
url = PinterestDL.get_image_url('link')
# => "https://i.pinimg.com/originals/8e/2a/..."

# Get video url
url = PinterestDL.get_video_url('link')
# => "https://v.pinimg.com/videos/..."