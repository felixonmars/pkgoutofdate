#!/usr/bin/ruby

require "ostruct"
require "optparse"
require "thread"
require "uri"

VERSION_DELEMITER_REGEX = '[\._\-]'
CURRENT_DIR = File.expand_path(File.dirname(__FILE__))

$options = OpenStruct.new

OUTPUT_MUTEX = Mutex.new # serializes output to console

def log(message)
  OUTPUT_MUTEX.synchronize {
    # write directly to file descriptor to avoid client side buffering
    $stdout.write(message + "\n")
  }
end

WEIRD_CORRECT_TYPES = %w(binary/octet-stream .gz)
APP_INCORRECT_TYPES = %w(xml)

def correct_content_type?(type)
  type.gsub!(/; charset=.*/, "") if type

  # content type should be 'application/XXX' where XXX one of the archive types
  return false unless type
  return true if WEIRD_CORRECT_TYPES.include?(type)
  return false unless type.start_with?("application/")
  return !APP_INCORRECT_TYPES.include?(type[12..-1])
end

def url_exists?(url)
  uri = URI.parse(url)
  host = uri.host
  # cut leading www if any
  host = host[4..-1] if host.start_with?("www.")

  case
  when ["ladspa.org", "download.videolan.org", "launchpad.net"].include?(host)
    # this site returns content type == 'text' for files
    system("curl --head -s -o /dev/null --fail #{url}")
  when host =~ /.+?\.googlecode\.com/
    # thank you googlecode for this bug https://code.google.com/p/support/issues/detail?id=660
    header = "If-Modified-Since: Tue, 11 Dec #{Time.now.year + 1} 10:10:24 GMT"
    system(%Q{curl --get -s -o /dev/null -w "%{http_code}" --header "#{header}" "#{url}" | grep -q 304})
  when %w(http https).include?(uri.scheme)
    type = `curl --head -L -s -o /dev/null -w "%{content_type}" "#{url}"`
    # TODO check response code here as well?
    correct_content_type?(type)
  when %w(ftp).include?(uri.scheme)
    system("curl --head -s -o /dev/null --fail #{url}")
  else
    false
  end
end

# parse version and supply list of possible next versions
def next_versions(ver, pkgname)
  result = []
  # version delimiters are [._-]
  split = ver.scan(/[\da-zA-Z]+|#{VERSION_DELEMITER_REGEX}/)

  # split is array of <number> <delimiter> <number> <delimiter> .. <number>
  reminder = []

  while true
    numpart = split.pop
    unless numpart =~ /\d+/
      log "#{pkgname}: unable to parse version #{ver} numpart is #{numpart}" if $options.verbose
      break
    end

    next_numpart = numpart.to_i + 1
    result.push(split.join + next_numpart.to_s + reminder.join)

    break if split.empty?

    reminder.unshift("0")
    delimiter = split.pop
    unless delimiter =~ /#{VERSION_DELEMITER_REGEX}/
      log "{pkgname}: unable to parse version #{ver} delimiter is #{delimiter}" if $options.verbose
      break
    end
    reminder.unshift(delimiter)
  end

  return result
end

def process_pkgbuild(pkgpath)
  pkgcontent = IO.read(pkgpath).force_encoding("ISO-8859-1").encode("utf-8", replace: nil)

  # instead of doing crazy regexp parsing let's shell do it
  sources = `bash -c "#{CURRENT_DIR}/parse_pkgbuild.sh #{pkgpath}"`.split("\n")

  pkgname = sources.shift
  pkgver = sources.shift

  unless pkgname or pkgver
    log "Cannot parse #{pkgpath}, no pkgname or pkgversion" if $options.verbose
    return
  end

  pkgver_regex = Regexp.new(pkgver.gsub(/#{VERSION_DELEMITER_REGEX}/, VERSION_DELEMITER_REGEX) + '\b')

  # Special case for custom directories. We can filter these packages at this stage only.
  return if not $options.pkg_whitelist.empty? and not $options.pkg_whitelist.include?(pkgname)

  return if sources.empty?

  sources.map! { |s| s.gsub(/(.*::)/, "") }

  sources.delete_if { |s| s !~ %r{^(http|https|ftp)://} }
  sources.delete_if { |s| s !~ pkgver_regex }

  if sources.empty?
    log "#{pkgname}: cannot find source urls in #{pkgpath}" if $options.verbose
    return
  end

  source = sources[0]
  source.strip!

  # Some of the Arch packages have non-compliant source urls. Fix it.
  # See https://github.com/anatol/pkgoutofdate/issues/4
  source.gsub!(' ', '%20')

  unless url_exists?(source)
    log "#{pkgname}: file does not exist on the server - #{pkgver} => #{sources}" if $options.verbose
  end

  for newver in next_versions(pkgver, pkgname)
    newurl = source.gsub(pkgver_regex, newver)
    if url_exists?(newurl)
      if url_exists?(source.gsub(pkgver_regex, pkgver + "102.2"))
        # we requested some weird version and server responded positively. weird....
        log "#{pkgname}: server responses 'file exists' for invalid version #{newurl}" if $options.verbose
      else
        log "#{pkgname}: new version found - #{pkgver} => #{newver}"
      end

      break
    end
  end
end

def find_packages
  # handle both flat and Arch-style directory structure
  Dir.glob("*/PKGBUILD") + Dir.glob("*/trunk/PKGBUILD")
end

QUEUE_MUTEX = Mutex.new # protects queue of PKGBUILD to process

def work_thread(queue)
  while true
    pkg = nil
    QUEUE_MUTEX.synchronize {
      pkg = queue.pop
    }
    return unless pkg

    process_pkgbuild(pkg)
  end
end

OptionParser.new do |opts|
  opts.banner = <<-eos
    Tool that checks whether new releases available for Arch packages.
    Tool iterates over packages directory, extracts downloadable url and tries to probe
    X.Y.Z+1, X.Y+1.0 and X+1.0.0 versions. If server responses OK for such urls then
    the tool assumes a new release available.

    Usage: pkgoutofdate.rb [options] [package_name]...
  eos

  # default value
  $options.threads_num = 12

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    $options.verbose = v
  end

  opts.on("--threads_num T", Integer, "Number of thread used for URL polling") do |t|
    $options.threads_num = t
  end

  opts.on("-d", "--directory D", String, "Directory where to scan for PKGBUILD files") do |d|
    unless File.directory?(d)
      puts "'#{d}' is not a directory"
      exit
    end

    $options.directory = d
  end
end.parse!

$options.pkg_whitelist = ARGV

if $options.directory
  Dir.chdir $options.directory
end

queue = find_packages()

if queue.empty?
  log "No packages found!"
  exit 1
end

threads = []
threads_num = [$options.threads_num, queue.size].min
for i in 1..threads_num
  threads << Thread.new { work_thread(queue) }
end
threads.each { |thr| thr.join }
