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
require 'pry'
require 'pry-byebug'
require 'tzinfo'
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

extras_str = 'date_upload,url_l'

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
    per_page: 50,
    page: 1,
    # Looks like unix time support is broken so use mysql time
    min_upload_date: begin_mysql_time
  }
photos_on_this_page = get_flickr_response(flickr_url, url_params, logger)
photos_per_page = photos_on_this_page['photos']['perpage'].to_i
logger.debug "STATUS from flickr API:#{photos_on_this_page['stat']} num_pages:\
  #{photos_on_this_page['photos']['pages'].to_i}"
PARAMS_TO_KEEP = %w[id dateupload url_l height_l width_l]
photos = []
photos_on_this_page['photos']['photo'].each do |photo|
  #logger.debug "photo from API: #{photo.ai}"
  dateupload = Time.at(photo['dateupload'].to_i)
  logger.debug "dateupload:#{dateupload}"
  photo['id'] = photo['id'].to_i
  photo['dateupload'] = photo['dateupload'].to_i
  next if !photo.has_key?('height_l') || photo['height_l'] < 640 # Skip all photos that are less than 640px high.

  photo_without_unnecessary_stuff = photo.slice(*PARAMS_TO_KEEP)
  logger.debug "photo without unneccesary stuff: #{photo_without_unnecessary_stuff.ai}"
  photos.push(photo_without_unnecessary_stuff)
end
photos.sort! { |a, b| a['dateupload'] <=> b['dateupload'] }
# Get last photo and figure out the date for the Pacific timezone
# and skip prior dates.
last = photos[-1]
tz = TZInfo::Timezone.get('America/Vancouver')
localtime = tz.to_local(Time.at(last['dateupload']))
localyyyy = localtime.strftime('%Y').to_i
localmm = localtime.strftime('%m').to_i
localdd = localtime.strftime('%d').to_i
startdate = tz.local_time(localyyyy, localmm, localdd, 0, 0).to_i
photos.reject! { |p| p['dateupload'] < startdate }
exit if photos.length.zero?
# Create barcode/yyyy/mm/dd directory if it doesn't exist
DIRECTORY = format(
  'barcode/%<yyyy>4.4d/%<mm>2.2d/%<dd>2.2d',
  yyyy: localyyyy, mm: localmm, dd: localdd
)
FileUtils.mkdir_p DIRECTORY
binding.pry
sleep 200
