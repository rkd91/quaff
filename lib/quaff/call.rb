# -*- coding: us-ascii -*-
require 'securerandom'
require 'timeout'
require_relative './utils.rb'
require_relative './sources.rb'
require_relative './auth.rb'
require_relative './message.rb'
require_relative './sip_dialog.rb'

module Quaff
  class CSeq # :nodoc:
    attr_reader :num
    def initialize cseq_str
      @num, @method = cseq_str.split
      @num = @num.to_i
    end

    def increment
      @num = @num + 1
      to_s
    end

    def to_s
      "#{@num.to_s} #{@method}"
    end
  end

class Call
  attr_reader :cid, :dialog

  def initialize(cxn,
                 cid,
                 my_uri,
                 target_uri,
                 destination=nil,
                 instance_id=nil)
    @cxn = cxn
    setdest(destination, recv_from_this: true) if destination
    @current_retrans = nil
    @retrans_keys = {}
    @t1, @t2 = 0.5, 32
    @instance_id = instance_id
    @dialog = SipDialog.new cid, my_uri, target_uri
    update_branch
  end

  def set_callee uri
    if /<(.*?)>/ =~ uri
      uri = $1
    end

    @dialog.target = uri unless uri.nil?
  end

  alias_method :set_dialog_target, :set_callee
  
  # Sets the Source where messages in this call should be sent to by
  # default.
  #
  # Options:
  #    :recv_from_this - if true, also listens for any incoming
  #    messages over this source's connection. (This is only
  #    meaningful for connection-oriented transports.)
  def setdest source, options={}
    @src = source
    if options[:recv_from_this] and source.sock
      @cxn.add_sock source.sock
    end
  end

  # Receives a SIP request.
  #
  # Options:
  #    :dialog_creating - whether the dialog state (peer tags, etc.)
  #    should be updated with information from this request. Defaults to true.
  def recv_request(method, options={})
    dialog_creating = options[:dialog_creating] || true
    begin
      msg = recv_something
    rescue Timeout::Error
      raise "#{ @uri } timed out waiting for #{ method }"
    end

    unless msg.type == :request \
      and Regexp.new(method) =~ msg.method
      raise((msg.to_s || "Message is nil!"))
    end

    @dialog.cseq = CSeq.new(msg.header("CSeq")).num
    
    if dialog_creating
      create_dialog_from_request msg
    end
    msg
  end

  # Waits until the next message comes in, and handles it if it is one
  # of possible_messages.
  #
  # possible_messages is a list of things that can be received.
  # Elements can be:
  # * a string representing the SIP method, e.g. "INVITE"
  # * a number representing the SIP status code, e.g. 200
  # * a two-item list, containing one of the above and a boolean
  # value, which indicates whether this message is dialog-creating. by
  # default, requests are assumed to be dialog-creating and responses
  # are not.
  #
  # For example, ["INVITE", 301, ["ACK", false], [200, true]] is a
  # valid value for possible_messages.
  def recv_any_of(possible_messages)
    begin
      msg = recv_something
    rescue Timeout::Error
      raise "#{ @uri } timed out waiting for one of these: #{possible_messages}"
    end

    found_match = false
    dialog_creating = nil
    
    possible_messages.each do
      | what, this_dialog_creating |
      type = if (what.class == String) then :request else :response end
      if this_dialog_creating.nil?
        this_dialog_creating = (type == :request)
      end

      found_match =
        if type == :request 
          msg.type == :request and what == msg.method
        else
          msg.type == :response and what.to_s == msg.status_code
        end

      if found_match
        dialog_creating = this_dialog_creating
        break
      end
    end

    unless found_match
      raise((msg.to_s || "Message is nil!"))
    end

    if dialog_creating
      create_dialog msg
    end
    msg
  end

  # Receives a SIP response.
  #
  # Options:
  #    :dialog_creating - whether the dialog state (peer tags, etc.)
  #    should be updated with information from this response. Defaults
  #    to false.
  #    :ignore_responses - a list of status codes to ignore (e.g.
  #    [100] will mean that 100 Tryings are ignored rather than
  #    treated as unexpected).
  def recv_response(code, options={})
    dialog_creating = options[:dialog_creating] || false
    ignore_responses = options[:ignore_responses] || [] 
    begin
      msg = recv_something
    rescue Timeout::Error
      raise "#{ @uri } timed out waiting for #{ code }"
    end

    if msg.type != :response
      raise "Expected #{code}, got #{msg}"
    elsif ignore_responses.include? msg.status_code
      return recv_response(code, options)
    else
      unless Regexp.new(code) =~ msg.status_code
        raise "Expected #{code}, got #{msg.status_code}"
      end
    end

    if dialog_creating
      create_dialog_from_response msg
    end

    msg
  end

  # Sends a SIP response with the given status code and reason phrase.
  #
  # Options:
  #    :body - the SIP body to use.
  #    :sdp_body - as :body, but an appropriate Content-Type header is
  #    automatically added.
  #    :response_to - a message to use the branch and CSeq from.
  #    Useful for responding to an INVITE after handling a CANCEL
  #    transaction.
  #    :retrans - whether or not to retransmit this periodically until
  #    the next message is received. Defaults to false.
  #    :headers - a map of headers to use in this message
  
  def send_response(code, phrase, options={})
    body = options[:body] || ""
    retrans = options[:retrans] || false
    headers = options[:headers] || {}
    if options[:sdp_body]
      body = options[:sdp_body]
      headers['Content-Type'] = "application/sdp"
    end

    if options[:response_to]
      assoc_with_msg(options[:response_to])
      headers['CSeq'] ||= CSeq.new(options[:response_to].header("CSeq"))
    end

    method = nil
    msg = build_message headers, body, :response, method, code, phrase
    send_something(msg, retrans)
  end

  # Sends a SIP request with the given method.
  #
  # Options:
  #    :body - the SIP body to use.
  #    :sdp_body - as :body, but an appropriate Content-Type header is
  #    automatically added.
  #    :new_tsx - whether to generate a new branch ID. Defaults to true.
  #    :same_tsx_as - a message to use the branch and CSeq from.
  #    Useful for ACKing to an INVITE after handling a PRACK
  #    transaction.
  #    :retrans - whether or not to retransmit this periodically until
  #    the next message is received. Defaults to true unless the
  #    method is ACK.
  #    :headers - a map of headers to use in this message
  def send_request(method, options={})
    body = options[:body] || ""
    headers = options[:headers] || {}
    new_tsx = options[:new_tsx].nil? ? true : options[:new_tsx]
    retrans =
      if options[:retrans].nil?
        if method == "ACK"
          false
        else
          true
        end
      else
        options[:retrans]
      end

    if options[:sdp_body]
      body = options[:sdp_body]
      headers['Content-Type'] = "application/sdp"
    end

    if options[:same_tsx_as]
      assoc_with_msg(options[:same_tsx_as])
    end

    if new_tsx
      update_branch
    end
    
    msg = build_message headers, body, :request, method
    send_something(msg, retrans)
  end

  def end_call
    @cxn.mark_call_dead @dialog.call_id
  end

  def get_next_hop header
    /<sip:(.+@)?(.+):(\d+);(.*)>/ =~ header
    sock = TCPSocket.new $2, $3
    return TCPSource.new sock
  end

  private
  def assoc_with_msg(msg)
    @last_Via = msg.all_headers("Via")
  end

  # Changes the branch parameter if the Via header, creating a new transaction
  def update_branch via_hdr=nil
    via_hdr ||= get_new_via_hdr
    @last_Via = via_hdr
  end

  alias_method :new_transaction, :update_branch

  def get_new_via_hdr
    "SIP/2.0/#{@cxn.transport} #{@cxn.local_hostname}:#{@cxn.local_port};rport;branch=#{Quaff::Utils::new_branch}"
  end

  def recv_something
    msg = @cxn.get_new_message @dialog.call_id
    @retrans_keys.delete @current_retrans
    @src = msg.source
    @last_Via = msg.headers["Via"]
    @last_CSeq = CSeq.new(msg.header("CSeq"))
    msg
  end

  def calculate_cseq type, method
    if (type == :response)
      @last_CSeq.to_s
    else
      if (method != "ACK") and (method != "CANCEL")
        @dialog.cseq += 1
      end
      "#{@dialog.cseq} #{method}"
    end
  end

  def build_message headers, body, type, method=nil, code=nil, phrase=nil
    is_request = code.nil?

    defaults = {
      "Call-ID" => @dialog.call_id,
      "CSeq" => calculate_cseq(type, method),
      "Via" => @last_Via,
      "Max-Forwards" => "70",
      "Content-Length" => "0",
      "User-Agent" => "Quaff SIP Scripting Engine",
      "Contact" => @cxn.contact_header
    }

    if is_request
      defaults['From'] = @dialog.local_fromto
      defaults['To'] = @dialog.peer_fromto
      defaults['Route'] = @dialog.routeset
    else
      defaults['To'] = @dialog.local_fromto
      defaults['From'] = @dialog.peer_fromto
      defaults['Record-Route'] = @dialog.routeset
    end

    defaults.merge! headers

    SipMessage.new(method, code, phrase, @dialog.target, body, defaults.merge!(headers)).to_s
  end

  def send_something(msg, retrans)
    @cxn.send_msg(msg, @src)
    if retrans and (@cxn.transport == "UDP") then
      key = SecureRandom::hex
      @current_retrans = key
      @retrans_keys[key] = true
      Thread.new do
        timer = @t1
        sleep timer
        while @retrans_keys[key] do
          #puts "Retransmitting #{ msg } on call #{ @dialog.call_id }"
          @cxn.send_msg(msg, @src)
          timer *=2
          if timer > @t2 then
            raise "Too many retransmits!"
          end
          sleep timer
        end
      end
    end
  end

  def create_dialog_from_request msg
    @dialog.established = true

    set_dialog_target msg.first_header("Contact")

    unless msg.all_headers("Record-Route").nil?
      @dialog.routeset = msg.all_headers("Record-Route")
    end

    @dialog.get_peer_info msg.header("From")
  end

  def create_dialog_from_response msg
    @dialog.established = true

    set_dialog_target msg.first_header("Contact")

    unless msg.all_headers("Record-Route").nil?
        @dialog.routeset = msg.all_headers("Record-Route").reverse
    end

    @dialog.get_peer_info msg.header("To")
  end
end
end
