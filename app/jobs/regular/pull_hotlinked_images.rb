require_dependency 'url_helper'
require_dependency 'file_helper'

module Jobs

  class PullHotlinkedImages < Jobs::Base
    include UrlHelper

    def initialize
      # maximum size of the file in bytes
      @max_size = SiteSetting.max_image_size_kb.kilobytes
    end

    def execute(args)
      return unless SiteSetting.download_remote_images_to_local?

      post_id = args[:post_id]
      raise Discourse::InvalidParameters.new(:post_id) unless post_id.present?

      post = Post.find_by(id: post_id)
      return unless post.present?

      raw = post.raw.dup
      start_raw = raw.dup
      downloaded_urls = {}

      extract_images_from(post.cooked).each do |image|
        src = image['src']
        src = "http:" + src if src.start_with?("//")

        if is_valid_image_url(src)
          hotlinked = nil
          begin
            # have we already downloaded that file?
            unless downloaded_urls.include?(src)
              begin
                hotlinked = FileHelper.download(src, @max_size, "discourse-hotlinked")
              rescue Discourse::InvalidParameters
              end
              if hotlinked
                if hotlinked.size <= @max_size
                  filename = File.basename(URI.parse(src).path)
                  upload = Upload.create_for(post.user_id, hotlinked, filename, hotlinked.size, { origin: src })
                  downloaded_urls[src] = upload.url
                else
                  Rails.logger.error("Failed to pull hotlinked image: #{src} - Image is bigger than #{@max_size}")
                end
              else
                Rails.logger.error("There was an error while downloading '#{src}' locally.")
              end
            end
            # have we successfully downloaded that file?
            if downloaded_urls[src].present?
              url = downloaded_urls[src]
              escaped_src = Regexp.escape(src)
              # there are 6 ways to insert an image in a post
              # HTML tag - <img src="http://...">
              raw.gsub!(/src=["']#{escaped_src}["']/i, "src='#{url}'")
              # BBCode tag - [img]http://...[/img]
              raw.gsub!(/\[img\]#{escaped_src}\[\/img\]/i, "[img]#{url}[/img]")
              # Markdown linked image - [![alt](http://...)](http://...)
              raw.gsub!(/\[!\[([^\]]*)\]\(#{escaped_src}\)\]/) { "[<img src='#{url}' alt='#{$1}'>]" }
              # Markdown inline - ![alt](http://...)
              raw.gsub!(/!\[([^\]]*)\]\(#{escaped_src}\)/) { "![#{$1}](#{url})" }
              # Markdown reference - [x]: http://
              raw.gsub!(/\[(\d+)\]: #{escaped_src}/) { "[#{$1}]: #{url}" }
              # Direct link
              raw.gsub!(src, "<img src='#{url}'>")
            end
          rescue => e
            Rails.logger.error("Failed to pull hotlinked image: #{src}\n" + e.message + "\n" + e.backtrace.join("\n"))
          ensure
            # close & delete the temp file
            hotlinked && hotlinked.close!
          end
        end

      end

      post.reload
      if start_raw != post.raw
        # post was edited - start over (after 10 minutes)
        backoff = args.fetch(:backoff, 1) + 1
        delay = SiteSetting.ninja_edit_window * args[:backoff]
        Jobs.enqueue_in(delay.seconds.to_i, :pull_hotlinked_images, args.merge!(backoff: backoff))
      elsif raw != post.raw
        options = {
          edit_reason: I18n.t("upload.edit_reason"),
          bypass_bump: true # we never want that job to bump the topic
        }
        post.revise(Discourse.system_user, raw, options)
      end
    end

    def extract_images_from(html)
      doc = Nokogiri::HTML::fragment(html)
      doc.css("img[src]") - doc.css(".onebox-result img") - doc.css("img.avatar")
    end

    def is_valid_image_url(src)
      # make sure we actually have a url
      return false unless src.present?
      # we don't want to pull uploaded images
      return false if Discourse.store.has_been_uploaded?(src)
      # we don't want to pull relative images
      return false if src =~ /\A\/[^\/]/i
      # parse the src
      begin
        uri = URI.parse(src)
      rescue URI::InvalidURIError
        return false
      end
      # we don't want to pull images hosted on the CDN (if we use one)
      return false if Discourse.asset_host.present? && URI.parse(Discourse.asset_host).hostname == uri.hostname
      # we don't want to pull images hosted on the main domain
      return false if URI.parse(Discourse.base_url_no_prefix).hostname == uri.hostname
      # check the domains blacklist
      SiteSetting.should_download_images?(src)
    end

  end

end
