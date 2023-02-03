#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
require 'typhoeus'
require 'amazing_print'
require 'json'
require 'time'
require 'date'
require 'csv'
require 'logger'
require 'io/console'
require 'parseconfig'
require 'fileutils'

def get_flickr_response(url, params, _logger)
  url = "https://api.flickr.com/#{url}"
  try_count = 0
  begin
    result = Typhoeus::Request.get(
      url,
      params: params
    )
    x = JSON.parse(result.body)
  rescue JSON::ParserError
    try_count += 1
    if try_count < 4
      logger.debug "JSON::ParserError exception, retry:#{try_count}"
      sleep(10)
      retry
    else
      logger.debug 'JSON::ParserError exception, retrying FAILED'
      x = nil
    end
  end
  x
end

logger = Logger.new($stderr)
logger.level = Logger::DEBUG

flickr_config = ParseConfig.new('flickr.conf').params
api_key = flickr_config['api_key']

TEN_MINUTES_IN_SECONDS = 60 * 10
BEGIN_TIME = Time.now.to_i - TEN_MINUTES_IN_SECONDS
logger.debug "BEGIN: #{BEGIN_TIME.ai}"
begin_mysql_time = Time.at(BEGIN_TIME).strftime('%Y-%m-%d %H:%M:%S')

extras_str = 'description, date_upload, date_taken, owner_name, url_l'

flickr_url = 'services/rest/'
logger.debug "begin_mysql_time:#{begin_mysql_time}"

url_params =
  {
    method: 'flickr.photos.search',
    media: 'photos', # Just photos no videos
    content_type: 1, # Just photos, no videos, screenshots, etc
    api_key: api_key,
    format: 'json',
    nojsoncallback: '1',
    extras: extras_str,
    sort: 'date-posted-asc',
    page: 1,
    # Looks like unix time support is broken so use mysql time
    min_upload_date: begin_mysql_time
  }
photos_on_this_page = get_flickr_response(flickr_url, url_params, logger)
photos_per_page = photos_on_this_page['photos']['perpage'].to_i
logger.debug "photos_per_page: #{photos_per_page}"

logger.debug "STATUS from flickr API:#{photos_on_this_page['stat']} num_pages:\
  #{photos_on_this_page['photos']['pages'].to_i}"
photos_on_this_page['photos']['photo'].each do |photo|
  logger.debug "photo from API: #{photo.ai}"
  date_taken = Time.parse(photo['datetaken'])
  logger.debug "date_taken:#{date_taken}"
  photo['id'] = photo['id'].to_i
  photo['description_content'] = photo['description']['_content']
  photo_without_nested_stuff = photo.except('description')
  logger.debug "photo without nested stuff: #{photo_without_nested_stuff.ai}"
  exit
end
