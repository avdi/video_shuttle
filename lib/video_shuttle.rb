require "typhoeus"
require "dotenv"
require "nokogiri"
require "ostruct"
require "json"
require "tempfile"

module VideoShuttle
  EPISODE_NUMBER_PATTERN = /
    (?<!\d)                   # preceded by non-digits
    \d{3}[a-z]?               # exactly three digits in a row (maybe 1 letter too)
    (?!\d)                    # followed by non-digits
  /x

  def self.shuttle_new_videos
    Dotenv.load
    puts "Getting list of available videos"
    dpd_login    = ENV.fetch("DPD_USER_LOGIN")
    dpd_password = ENV.fetch("DPD_USER_PASSWORD")
    response = Typhoeus.get(
      "https://rubytapas.dpdcart.com/feed",
      userpwd: "#{dpd_login}:#{dpd_password}")
    response.code == 200 or die "Feed fetch failed", response
    return response
    feed_doc = Nokogiri::XML(response.body)
    items = feed_doc.xpath("//item")
    episodes = items.map{|item|
      title  = item.at_xpath("./title").text
      number = EPISODE_NUMBER_PATTERN.match(title)[0]
      OpenStruct.new(
        title: title,
        video_url: item.at_xpath("./enclosure")["url"],
        number: number)
    }

    puts "Getting Wistia project list"
    wistia_api_password = ENV.fetch("WISTIA_API_PASSWORD")
    response = Typhoeus.get(
      "https://api.wistia.com/v1/projects.json",
      userpwd: "api:#{wistia_api_password}")
    projects = JSON.parse(response.body)
    project = projects.detect{|p| p["name"] == "RubyTapas Complete"} or
      die "Project not found", projects
    project_hashed_id = project["hashedId"] or die "No hashed ID", project

    puts "Listing project videos"
    response = Typhoeus.get(
      "https://api.wistia.com/v1/projects/#{project_hashed_id}.json",
      userpwd: "api:#{wistia_api_password}")
    response.code == 200 or die "Failed to fetch projects", response
    project_info = JSON.parse(response.body)
    medias = project_info["medias"]
    wistia_videos = medias.flat_map {|media|
      if media["type"] == "Video"
        number = EPISODE_NUMBER_PATTERN.match(media["name"])[0]
        [OpenStruct.new(name: media["name"], number: number, hashed_id: media["hashed_id"])]
      else
        []
      end
    }

    puts "Calculating missing episodes"
    available_numbers = episodes.map(&:number)
    posted_numbers    = wistia_videos.map(&:number)
    missing_numbers   = available_numbers - posted_numbers
    puts "Need to shuttle episodes: #{missing_numbers}"

    missing_episodes = episodes.select{|e| missing_numbers.include?(e.number)}

    puts "Uploading episodes"
    missing_episodes.each do |episode|
      puts "Downloading episode #{episode.title}"
      extname  = File.extname(episode.video_url)
      basename = File.basename(episode.video_url, extname)
      bytes          = 0
      expected_bytes = 0
      Tempfile.open([basename, extname]) do |f|
        puts "Downloading episode to #{f.path}"
        request = Typhoeus::Request.new(
          episode.video_url,
          userpwd: "#{dpd_login}:#{dpd_password}")
        request.on_headers do |response|
          unless response.success?
            die "Download of #{episode.title} failed", response
          end
          expected_bytes = response.headers_hash["Content-Length"].to_i
          puts "Expecting #{expected_bytes} bytes"
        end
        request.on_body do |chunk|
          f.write(chunk)
          bytes += chunk.size
        end
        request.on_complete do |response|
          puts "Finished downloading #{bytes} of #{expected_bytes} to #{f.path}"
          f.close
        end
        request.run

        f.open

        puts "Uploading #{episode.title} from #{f.path} (#{bytes} bytes)"
        response = Typhoeus.post(
          "https://upload.wistia.com/",
          body: {
            name: episode.title,
            api_password: wistia_api_password,
            project_id: project_hashed_id,
            file: f,
          })
        response.code == 200 or die "Failed to upload", response
        puts "Finished uploading #{episode.name}"
      end
    end

    puts "Fixing up names"
    wistia_videos.each do |video|
      episode = episodes.detect{|e| e.number == video.number}
      unless episode.title == video.name
        puts "Updating #{video.name} to '#{episode.title}'"
        response = Typhoeus.put(
          "https://api.wistia.com/v1/medias/#{video.hashed_id}.json",
          userpwd: "api:#{wistia_api_password}",
          body: {
            name: episode.title
          })
        response.code == 200 or die "Failed to update", response
      end
    end
  end

  def self.die(message, info=nil)
    p info if info
    raise message
  end
end
