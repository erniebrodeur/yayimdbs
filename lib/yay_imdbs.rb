# encoding: UTF-8
require 'open-uri'
require 'nokogiri'

begin
  # Rails 3
  require 'active_support/core_ext/object'
  require 'active_support/core_ext/hash/indifferent_access.rb'
rescue
  # Rails 2.3
  require 'active_support/all'
end

class YayImdbs 
  IMDB_BASE_URL = 'http://www.imdb.com/'
  IMDB_SEARCH_URL = IMDB_BASE_URL + 'find?s=tt&q='
  IMDB_MOVIE_URL = IMDB_BASE_URL + 'title/tt'

  STRIP_WHITESPACE = /(\s{2,}|\n|\||\302\240\302\273)/u

  class << self

    def search_for_imdb_id(name, year=nil, type=nil)
      search_results = self.search_imdb(name)
      return nil if search_results.empty?
    
      search_results.each do |result|
        # Ensure result is the correct video type
        next if type && (result[:video_type] != type)
      
        # If no year provided just return first result
        return result[:imdb_id] if !year || result[:year] == year
      end
      return nil  
    end

    def search_imdb(search_term)
      search_results = []
    
      doc = self.get_search_page(search_term)
      # If the search is an exact match imdb will redirect to the movie page not search results page
      # we uses the title meta element to determine if we got an exact match
      movie_title, movie_year = get_title_and_year_from_meta(doc)
      if movie_title
        canonical_link = doc.xpath("//link[@rel='canonical']")
        if canonical_link && canonical_link.first['href'] =~ /tt(\d+)\//
          return [:name => movie_title, :year => movie_year, :imdb_id => $1, :video_type => self.video_type_from_meta(doc)]
        else
          raise "Unable to extract imdb id from exact search result"
        end
      end
    
      doc.xpath("//td").each do |td| 
        td.xpath(".//a").each do |link|  
          href = link['href']
          current_name = link.content

          # Ignore links with no text (e.g. image links)
          next unless current_name.present?
          current_name = self.clean_title(current_name)
        
          if href =~ /^\/title\/tt(\d+)/
            imdb_id = $1
            current_year = $1.gsub(/\(\)/, '').to_i if td.inner_text =~ /\((\d{4}\/?\w*)\)/
            search_results << {:imdb_id => imdb_id, :name => current_name, :year => current_year, :video_type => self.video_type(td)}
          end
        end
      end
    
      return search_results
    end  

    def scrap_movie_info(imdb_id)
      info_hash = {:imdb_id => imdb_id}.with_indifferent_access
    
      doc = self.get_movie_page(imdb_id)
      info_hash['title'], info_hash['year'] = get_title_and_year_from_meta(doc)
      if info_hash['title'].nil?
        #If we cant get title and year something is wrong
        raise "Unable to find title or year for imdb id #{imdb_id}"
      end
      info_hash['video_type'] = self.video_type_from_meta(doc)
      
      info_hash[:plot] = doc.xpath("//td[@id='overview-top']/p[2]").inner_text.strip

      found_info_divs = false
      doc.xpath("//div/h4").each do |h4|
        div = h4.parent
        found_info_divs = true
        raw_key = h4.inner_text
        key = raw_key.sub(':', '').strip.downcase
        value = div.inner_text[((div.inner_text =~ /#{Regexp.escape(raw_key)}/) + raw_key.length).. -1]
        value = value.gsub(/\302\240\302\273/u, '').strip.gsub(/(See more)|(see all)$/, '').strip
        
        if key == 'release date'
          begin
            value = Date.strptime(value, '%d %B %Y')
          rescue 
            p "Invalid date '#{value}' for imdb id: #{imdb_id}"
            value = nil
          end
        elsif key == 'runtime'
          if value =~ /(\d+)\smin/
            value = $1.to_i
          else
            p "Unexpected runtime format #{value} for movie #{imdb_id}"
          end
        elsif key == 'genres'
          value = value.split('|').collect { |l| l.gsub(/[^a-zA-Z0-9\-]/, '') }
          # Backwards compatibility hack
          info_hash[:genre] = value
        elsif key == 'year'
          value = value.split('|').collect { |l| l.strip.to_i }.reject { |y| y <= 0 }
          # TV shows can have multiple years
          info_hash[:years] = value
          value = value.sort.first
        elsif key == 'language'
          value = value.split('|').collect { |l| l.gsub(/[^a-zA-Z0-9]/, '') }
        elsif key == 'taglines'
          # Backwards compatibility
          info_hash['tagline'] = value
        elsif key == 'motion picture rating (mpaa)'
          value = value.gsub(/See all certifications/, '').strip
          # Backwards compatibility FIXME do with a map
          info_hash['mpaa'] = value
        end
        info_hash[key.downcase.gsub(/\s/, '_')] = value
      end
    
      if not found_info_divs
        #If we don't find any info divs assume parsing failed
        raise "No info divs found for imdb id #{imdb_id}"
      end
    
      self.scrap_images(doc, info_hash)
    
      #scrap episodes if tv series
      if info_hash.has_key?('season')
        self.scrap_episodes(info_hash)
      end
    
      return info_hash 
    end

     def scrap_images(doc, info_hash)
      #scrap poster image urls
      thumb = doc.xpath("//td[@id = 'img_primary']/a/img")
      if thumb.first
        thumbnail_url = thumb.first['src']
        if not thumbnail_url =~ /\/nopicture\// 
          info_hash['medium_image'] = thumbnail_url

          # Small thumbnail image, gotten by hacking medium url
          info_hash['small_image'] = thumbnail_url.sub(/@@.*$/, '@@._V1._SX120_120,160_.jpg')
        
          #Try to scrap a larger version of the image url
          large_img_page = doc.xpath("//td[@id = 'img_primary']/a").first['href']
          large_img_doc = self.get_media_page(large_img_page) 
          large_img_url = large_img_doc.xpath("//img[@id = 'primary-img']").first['src'] unless large_img_doc.xpath("//img[@id = 'primary-img']").empty?
          info_hash['large_image'] = large_img_url
        end
      end
     end

     def scrap_episodes(info_hash)
        episodes = []
        doc = self.get_episodes_page(info_hash[:imdb_id])
        episode_divs = doc.css(".filter-all")
        episode_divs.each do |e_div|
          if e_div.xpath('.//h3').inner_text =~ /Season (\d+), Episode (\d+):/
            episode = {"series" => $1.to_i, "episode" => $2.to_i, "title" => $'.strip}
            raw_date = e_div.xpath('.//span/strong').inner_text.strip
            episode['date'] = Date.parse(raw_date)
            if e_div.inner_text =~ /#{raw_date}/
              episode['plot'] = $'.strip
            end
            episodes << episode
          end
        end
        info_hash['episodes'] = episodes
     end

      def get_search_page(name)
        Nokogiri::HTML(open(IMDB_SEARCH_URL + URI.escape(name)))
      end

      def get_movie_page(imdb_id)
        Nokogiri::HTML(open(IMDB_MOVIE_URL + imdb_id))
      end

      def get_episodes_page(imdb_id)
        Nokogiri::HTML(open(IMDB_MOVIE_URL + imdb_id + '/episodes'))
      end

      def get_media_page(url_fragment)
        Nokogiri::HTML(open(IMDB_BASE_URL + url_fragment))
       end

      def get_title_and_year_from_meta(doc)
        title_text = doc.at_css("meta[name='title']").try(:[], 'content')
        # Matches 'Movie Name (2010)' or 'Movie Name (2010/I)' or 'Lost (TV Series 2004–2010)'
        if title_text && title_text =~ /(.*) \([^\)0-9]*(\d{4})((\/\w*)|(.\d{4}))?\)/
          movie_title = self.clean_title($1)
          movie_year = $2.to_i
        end
        return movie_title, movie_year
      end  

      # Remove surrounding double quotes that seems to appear on tv show name
      def clean_title(movie_title)
        movie_title = $1 if movie_title =~ /^"(.*)"$/
        return movie_title.strip
      end  
    
      # Hackyness to get around ruby 1.9 encoding issue
      def strip_whitespace(s)
        s.encode('UTF-8').gsub(STRIP_WHITESPACE, '').strip
      end  
    
      def video_type(td)
        return :tv_show if td.content =~ /\((TV series|TV)\)/
        return :movie
      end 
    
      def video_type_from_meta(doc)
        type_text = doc.at_css("meta[property='og:type']").try(:[], 'content')
        type_text == 'tv_show' ? :tv_show : :movie
      end

    end
end
