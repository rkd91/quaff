require 'socket'

module Quaff

module Utils #:nodoc:
def Utils.local_ip
    Socket.ip_address_list.detect {|i| i.ipv4_private?}
end

def Utils.pid
    Process.pid
end

def Utils.new_call_id
    "#{pid}_#{Time.new.to_i}@#{local_ipv4}"
end

def Utils.new_branch
    "z9hG4bK#{Time.new.to_f}"
end

def Utils.paramhash_to_str params
  params.collect {|k, v| if (v == true) then ";#{k}" else ";#{k}=#{v}" end}.join("")
end

end
end
