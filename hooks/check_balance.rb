#!/usr/bin/env ruby
# -------------------------------------------------------------------------- #
# Copyright 2021, IONe Cloud Project, Support.by                             #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
# -------------------------------------------------------------------------- #

require 'base64'
require 'nokogiri'

xml = Nokogiri::XML(Base64::decode64(ARGV[1]))
unless xml.xpath("/CALL_INFO/RESULT").text.to_i == 1 then
    puts "VM wasn't allocated, skipping"
    exit 0
end

vmid = nil
if ARGV.first == 'vm' then
    vmid = xml.xpath('//ID').text.to_i
elsif ARGV.first == 'tmpl' then
    vmid = xml.xpath('/CALL_INFO/PARAMETERS/PARAMETER[TYPE="OUT"][POSITION=2]/VALUE').text.to_i
else
    puts "IDK what to do🤷‍♂️"
    exit 0
end

RUBY_LIB_LOCATION = "/usr/lib/one/ruby"
ETC_LOCATION      = "/etc/one/"

$: << RUBY_LIB_LOCATION

require 'opennebula'
include OpenNebula

vm = VirtualMachine.new_with_id(vmid, Client.new)
vm.lock 0
vm.info!

u = User.new_with_id vm['UID'].to_i, Client.new
u.info!
balance = u['TEMPLATE/BALANCE'].to_f

vm.recover 3 if balance == 0

require 'yaml'
require 'json'
require 'sequel'

$ione_conf = YAML.load_file("/etc/one/ione.conf") # IONe configuration constants

require $ione_conf['DB']['adapter']
$db = Sequel.connect({
        adapter: $ione_conf['DB']['adapter'].to_sym,
        user: $ione_conf['DB']['user'], password: $ione_conf['DB']['pass'],
        database: $ione_conf['DB']['database'], host: $ione_conf['DB']['host']  })

conf = $db[:settings].as_hash(:name, :body)

capacity = JSON.parse(conf['CAPACITY_COST'])
vm_price = capacity['CPU_COST'].to_f * vm['//TEMPLATE/VCPU'].to_i + capacity['MEMORY_COST'].to_f * vm['//TEMPLATE/MEMORY'].to_i / 1000

if balance < vm_price * 86400 then
    puts "User balance isn't enough to deploy this VM, deleting..."
    vm.recover 3
else
    puts "User has enough balance, do whatever you want"
    vm.unlock
end

