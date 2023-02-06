#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
require 'typhoeus'
require 'amazing_print'
require 'time'
require 'date'
require 'logger'
require 'io/console'
require 'parseconfig'
require 'fileutils'
require 'pry'
require 'pry-byebug'
require 'tzinfo'
require 'down/http'
require 'json'
require 'rmagick'

include Magick

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

NUM_PHOTOS_TO_DOWNLOAD = 20

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
    per_page: NUM_PHOTOS_TO_DOWNLOAD,
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
  # logger.debug "photo from API: #{photo.ai}"
  dateupload = Time.at(photo['dateupload'].to_i)
  logger.debug "dateupload:#{dateupload}"
  photo['id'] = photo['id'].to_i
  photo['dateupload'] = photo['dateupload'].to_i
  next if !photo.has_key?('height_l') || photo['height_l'] < 640 # Skip all photos that are less than 640px high.

  photo_without_unnecessary_stuff = photo.slice(*PARAMS_TO_KEEP)
  logger.debug "photo without unnecessary stuff: #{photo_without_unnecessary_stuff.ai}"
  photos.push(photo_without_unnecessary_stuff)
end
photos.sort! { |a, b| a['dateupload'] <=> b['dateupload'] }
# Get last photo and figure out the date for the Pacific timezone
# and skip prior dates (if there are any)
last = photos[-1]
tz = TZInfo::Timezone.get('America/Vancouver')
localtime = tz.to_local(Time.at(last['dateupload']))
localyyyy = localtime.strftime('%Y').to_i
localmm = localtime.strftime('%m').to_i
localdd = localtime.strftime('%d').to_i
startdate = tz.local_time(localyyyy, localmm, localdd, 0, 0).to_i
photos.reject! { |p| p['dateupload'] < startdate }
exit if photos.length.zero?
BARCODE_SLICE = '/tmp/resized.png'
HEIGHT = 640
WIDTH = 1
# Create barcode/yyyy/mm/dd directory if it doesn't exist
DIRECTORY = format(
  'barcode/%<yyyy>4.4d/%<mm>2.2d/%<dd>2.2d',
  yyyy: localyyyy, mm: localmm, dd: localdd
)
ID_FILEPATH = "#{DIRECTORY}/processed-ids.txt"
BARCODE_FILEPATH = 'barcode/barcode.png'
DAILY_BARCODE_FILEPATH = format(
  '%<dir>s/%<yyyy>4.4d-%<mm>2.2d-%<dd>2.2d.png',
  dir: DIRECTORY, yyyy: localyyyy, mm: localmm, dd: localdd
)
FileUtils.mkdir_p DIRECTORY
processed_ids = []
processed_ids = IO.readlines(ID_FILEPATH).map(&:to_i) if File.exist?(ID_FILEPATH)
photos.each do |photo|
  id = photo['id']
  next if processed_ids.include?(id)

  # Download the thumbnail to /tmp
  logger.debug "DOWNLOADING #{id}"
  # 604 height files shouldn't be more than 1 MB!!!
  tempfile = Down::Http.download(photo['url_l'], max_size: 1 * 1024 * 1024)
  thumb = Image.read(tempfile.path).first
  resized = thumb.resize(WIDTH, HEIGHT)
  resized.write(BARCODE_SLICE)
  if !File.exist?(DAILY_BARCODE_FILEPATH)
    FileUtils.cp(BARCODE_SLICE, DAILY_BARCODE_FILEPATH)
  else
    todays_barcode = Image.read(DAILY_BARCODE_FILEPATH).first
    #  montage -geometry +0+0 -tile x1 $first1000  pmbarcode1000.png
    image_list = Magick::ImageList.new(DAILY_BARCODE_FILEPATH, BARCODE_SLICE)
    montaged_images = image_list.montage { |image| image.tile = '2x1', image.geometry = '+0+0' }
    montaged_images.write(DAILY_BARCODE_FILEPATH)
  end
  File.delete(tempfile.path)
  # After the thumbnail is downloaded,  add the id to the file and to the array
  # so we don't download it again!
  File.open(ID_FILEPATH, 'a') { |f| f.write("#{id}\n") }
  processed_ids.push(id)
  FileUtils.cp(DAILY_BARCODE_FILEPATH, BARCODE_FILEPATH)
end