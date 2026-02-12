# pinterest-dl

Get direct image and video URLs from Pinterest:)

![Pinterest-DL Demo](https://cdn.imgurl.ir/uploads/k178865_IMG_2555-ezgif_com-video-to-gif-converter.gif)

```ruby
gem install pinterest-dl

```

## Usage

```ruby
require 'pinterest-dl'
```


# Get image url
```ruby 
url = PinterestDL.get_image_url('link')
```
=> "https://i.pinimg.com/originals/8e/2a/..."

# Get video url
```ruby
url = PinterestDL.get_video_url('link')
```
=> "https://v.pinimg.com/videos/..."
