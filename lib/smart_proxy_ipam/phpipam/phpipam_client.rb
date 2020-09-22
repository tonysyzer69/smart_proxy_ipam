require 'yaml'
require 'json'
require 'net/http'
require 'monitor'
require 'concurrent'
require 'time'
require 'uri'
require 'sinatra'
require 'smart_proxy_ipam/ipam'
require 'smart_proxy_ipam/ipam_helper'
require 'smart_proxy_ipam/api_resource'
require 'smart_proxy_ipam/ip_cache'

module Proxy::Ipam
  # Implementation class for External IPAM provider phpIPAM
  class PhpipamClient
    include Proxy::Log
    include Proxy::Ipam::IpamHelper

    @ip_cache = nil
    MAX_RETRIES = 5

    def initialize(conf)
      @conf = conf
      @api_base = "#{@conf[:url]}/api/#{@conf[:user]}/"
      @token = authenticate('/user/')
      @api_resource = ApiResource.new(api_base: @api_base, token: @token, auth_header: 'Token')
      @ip_cache = IpCache.new(provider: "phpipam")
    end

    def get_ipam_subnet(cidr, group_id = nil)
      if group_id.nil? || group_id.empty?
        get_ipam_subnet_by_cidr(cidr)
      else
        get_ipam_subnet_by_group(cidr, group_id)
      end
    end

    def get_ipam_subnet_by_group(cidr, group_id)
      subnets = get_ipam_subnets(group_id)
      return nil if subnets.nil?
      subnet_id = nil

      subnets.each do |subnet|
        subnet_cidr = subnet[:subnet] + '/' + subnet[:mask]
        subnet_id = subnet[:id] if subnet_cidr == cidr
      end

      return nil if subnet_id.nil?
      response = @api_resource.get("subnets/#{subnet_id}/")
      json_body = JSON.parse(response.body)

      data = {
        id: json_body['data']['id'],
        subnet: json_body['data']['subnet'],
        mask: json_body['data']['mask'],
        description: json_body['data']['description']
      }

      return data if json_body['data']
    end

    def get_ipam_subnet_by_cidr(cidr)
      subnet = @api_resource.get("subnets/cidr/#{cidr}")
      json_body = JSON.parse(subnet.body)
      return nil if json_body['data'].nil?

      data = {
        id: json_body['data'][0]['id'],
        subnet: json_body['data'][0]['subnet'],
        mask: json_body['data'][0]['mask'],
        description: json_body['data'][0]['description']
      }

      return data if json_body['data']
    end

    def get_ipam_group(group_name)
      return nil if group_name.nil?
      group = @api_resource.get("sections/#{group_name}/")
      json_body = JSON.parse(group.body)
      return nil if json_body['data'].nil?

      data = {
        id: json_body['data']['id'],
        name: json_body['data']['name'],
        description: json_body['data']['description']
      }

      return data if json_body['data']
    end

    def get_ipam_groups
      groups = @api_resource.get('sections/')
      json_body = JSON.parse(groups.body)
      return nil if json_body['data'].nil?

      data = []
      json_body['data'].each do |group|
        data.push({
          id: group['id'],
          name: group['name'],
          description: group['description']
        })
      end

      return data if json_body['data']
    end

    def get_ipam_subnets(group_name)
      group = get_ipam_group(group_name)
      raise errors[:no_subnet] if group.nil?
      subnets = @api_resource.get("sections/#{group[:id]}/subnets/")
      json_body = JSON.parse(subnets.body)
      return nil if json_body['data'].nil?

      data = []
      json_body['data'].each do |subnet|
        data.push({
          id: subnet['id'],
          subnet: subnet['subnet'],
          mask: subnet['mask'],
          description: subnet['description']
        })
      end

      return data if json_body['data']
    end

    def ip_exists?(ip, subnet_id)
      ip = @api_resource.get("subnets/#{subnet_id}/addresses/#{ip}/")
      json_body = JSON.parse(ip.body)
      json_body['success']
    end

    def add_ip_to_subnet(ip, params)
      data = { subnetId: params[:subnet_id], ip: ip, description: 'Address auto added by Foreman' }
      subnet = @api_resource.post('addresses/', data.to_json)
      json_body = JSON.parse(subnet.body)
      return nil if json_body['code'] == 201
      { error: 'Unable to add IP to External IPAM' }
    end

    def delete_ip_from_subnet(ip, params)
      subnet = @api_resource.delete("addresses/#{ip}/#{params[:subnet_id]}/")
      json_body = JSON.parse(subnet.body)
      return nil if json_body['success']
      { error: 'Unable to delete IP from External IPAM' }
    end

    def get_next_ip(mac, cidr, group_name)
      subnet = get_ipam_subnet(cidr, group_name)
      raise errors[:no_subnet] if subnet.nil?
      response = @api_resource.get("subnets/#{subnet[:id]}/first_free/")
      json_body = JSON.parse(response.body)
      group = group_name.nil? ? '' : group_name
      @ip_cache.set_group(group, {}) if @ip_cache.get_group(group).nil?
      subnet_hash = @ip_cache.get_cidr(group, cidr)
      next_ip = nil

      return { message: json_body['message'] } if json_body['message']

      if subnet_hash&.key?(mac.to_sym)
        next_ip = @ip_cache.get_ip(group, cidr, mac)
      else
        new_ip = json_body['data']
        ip_not_in_cache = subnet_hash.nil? ? true : !subnet_hash.to_s.include?(new_ip.to_s)

        if ip_not_in_cache
          next_ip = new_ip.to_s
          @ip_cache.add(new_ip, mac, cidr, group)
        else
          next_ip = find_new_ip(subnet[:id], new_ip, mac, cidr, group)
        end

        return { error: "Unable to find another available IP address in subnet #{cidr}" } if next_ip.nil?
        return { error: "It is possible that there are no more free addresses in subnet #{cidr}. Available IP's may be cached, and could become available after in-memory IP cache is cleared(up to #{@ip_cache.get_cleanup_interval} seconds)." } unless usable_ip(next_ip, cidr)
      end

      return nil if no_free_ip_found?(next_ip)

      next_ip
    end

    def no_free_ip_found?(ip)
      ip.is_a?(Hash) && ip['message'] && ip['message'].downcase == 'no free addresses found'
    end

    def groups_supported?
      true
    end

    def authenticated?
      !@token.nil?
    end

    def subnet_exists?(subnet)
      !(subnet[:message] && subnet[:message].downcase == 'no subnet found')
    end

    def authenticate(path)
      auth_uri = URI(@api_base + path)
      request = Net::HTTP::Post.new(auth_uri)
      request.basic_auth @conf[:user], @conf[:password]
  
      response = Net::HTTP.start(auth_uri.hostname, auth_uri.port, use_ssl: auth_uri.scheme == 'https') do |http|
        http.request(request)
      end
  
      response = JSON.parse(response.body)
      logger.warn(response['message']) if response['message']
      response.dig('data', 'token')
    end

    private

    # Called when next available IP from external IPAM has been cached by another user/host, but
    # not actually persisted in external IPAM. Will increment the IP(MAX_RETRIES times), and
    # see if it is available in external IPAM.
    def find_new_ip(subnet_id, ip, mac, cidr, group_name)
      found_ip = nil
      temp_ip = ip
      retry_count = 0

      loop do
        new_ip = increment_ip(temp_ip)
        ipam_ip = ip_exists?(new_ip, subnet_id)

        # If new IP doesn't exist in IPAM and not in the cache
        if !ipam_ip && !@ip_cache.ip_exists(new_ip, cidr, group_name)
          found_ip = new_ip.to_s
          @ip_cache.add(found_ip, mac, cidr, group_name)
          break
        end

        temp_ip = new_ip
        retry_count += 1
        break if retry_count >= MAX_RETRIES
      end

      # Return the original IP found in external ipam if no new ones found after MAX_RETRIES
      return ip if found_ip.nil?

      found_ip
    end
  end
end
