#!/usr/bin/env ruby
# Provision the Broadcast Mirror app + broadcast extension via the App Store
# Connect API, then install IOS_APP_DEVELOPMENT profiles. Manual signing — no
# xcodebuild auto-provision (`-allowProvisioningUpdates` returns "Authentication
# failed" when creating NEW App IDs against this key, even though the raw API
# authenticates fine; provision via the API + manual-sign). Idempotent.
#
# Env:
#   APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID  (source ~/.config/appstoreconnect/env)
#   DEV_CERT_SERIAL   local "Apple Development" cert serial (security find-identity ... )
#   DEVICE_UDID       target phone udid   (xctrace list devices)
#   DEVICE_NAME       optional label      (default BMDEV3)
#   APP_BUNDLE_ID / EXT_BUNDLE_ID / APP_PROFILE_NAME / EXT_PROFILE_NAME  (defaults below)
# Writes prov.env with the profile names for build.sh.
require 'openssl'; require 'base64'; require 'json'; require 'net/http'; require 'fileutils'; require 'uri'

KID  = ENV.fetch('APP_STORE_CONNECT_KEY_ID')
ISS  = ENV.fetch('APP_STORE_CONNECT_ISSUER_ID')
TEAM = ENV.fetch('DEVELOPMENT_TEAM', 'RA9PQ9434F')
CERT_SERIAL = ENV.fetch('DEV_CERT_SERIAL')
DEVICE_UDID = ENV.fetch('DEVICE_UDID')
DEVICE_NAME = ENV.fetch('DEVICE_NAME', 'BMDEV3')
APP_BID  = ENV.fetch('APP_BUNDLE_ID', 'net.busymate.mirror')
EXT_BID  = ENV.fetch('EXT_BUNDLE_ID', 'net.busymate.mirror.upload')
APP_PROF = ENV.fetch('APP_PROFILE_NAME', 'Busymate Mirror Dev')
EXT_PROF = ENV.fetch('EXT_PROFILE_NAME', 'Busymate Mirror Upload Dev')
KEY_PATH = ENV.fetch('APP_STORE_CONNECT_API_KEY_PATH', File.expand_path('~/.config/appstoreconnect/key.p8'))
KEY  = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
PROFILE_DIR = File.expand_path('~/Library/MobileDevice/Provisioning Profiles')

def b64(x); Base64.urlsafe_encode64(x).delete('='); end
def jwt
  hdr=b64({alg:'ES256',kid:KID,typ:'JWT'}.to_json); now=Time.now.to_i
  pay=b64({iss:ISS,iat:now,exp:now+600,aud:'appstoreconnect-v1'}.to_json)
  data="#{hdr}.#{pay}"; der=KEY.sign(OpenSSL::Digest::SHA256.new,data)
  a=OpenSSL::ASN1.decode(der); r=a.value[0].value.to_s(2).rjust(32,"\x00"); s=a.value[1].value.to_s(2).rjust(32,"\x00")
  "#{data}.#{b64(r+s)}"
end
def api(method, path, body=nil)
  uri=URI("https://api.appstoreconnect.apple.com#{path}")
  klass={get:Net::HTTP::Get,post:Net::HTTP::Post,delete:Net::HTTP::Delete}[method]
  req=klass.new(uri); req['Authorization']="Bearer #{jwt}"; req['Content-Type']='application/json'
  req.body=body.to_json if body
  res=Net::HTTP.start(uri.host,uri.port,use_ssl:true){|h|h.request(req)}
  parsed={}
  if res.body && !res.body.empty?
    begin; parsed=JSON.parse(res.body); rescue; parsed={'raw'=>res.body}; end
  end
  [res.code.to_i, parsed]
end

def ensure_bundle(identifier, name)
  code, d = api(:get, "/v1/bundleIds?filter[identifier]=#{identifier}&limit=1")
  if code==200 && d['data'] && !d['data'].empty?
    id=d['data'][0]['id']; puts "bundleId #{identifier} exists id=#{id}"; return id
  end
  code, d = api(:post, "/v1/bundleIds", {data:{type:'bundleIds',attributes:{identifier:identifier,name:name,platform:'IOS',seedId:TEAM}}})
  raise "create bundleId #{identifier} -> #{code} #{d}" unless code==201
  id=d['data']['id']; puts "bundleId #{identifier} created id=#{id}"; id
end

def ensure_device
  code, d = api(:get, "/v1/devices?filter[udid]=#{DEVICE_UDID}&limit=1")
  if code==200 && d['data'] && !d['data'].empty?
    id=d['data'][0]['id']; puts "device #{DEVICE_UDID} exists id=#{id}"; return id
  end
  code, d = api(:post, "/v1/devices", {data:{type:'devices',attributes:{name:DEVICE_NAME,platform:'IOS',udid:DEVICE_UDID}}})
  return d['data']['id'] if code==201
  code, d = api(:get, "/v1/devices?filter[udid]=#{DEVICE_UDID}&limit=1")
  raise "device provision failed #{code} #{d}" unless code==200 && d['data'] && !d['data'].empty?
  d['data'][0]['id']
end

def dev_cert_id
  code, d = api(:get, "/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200")
  raise "list certs #{code}" unless code==200
  want = CERT_SERIAL.gsub(/^0+/,'').upcase
  match = d['data'].find { |c| (c.dig('attributes','serialNumber')||'').gsub(/^0+/,'').upcase == want } || d['data'].first
  raise "no DEVELOPMENT cert found" unless match
  puts "cert id=#{match['id']} serial=#{match.dig('attributes','serialNumber')}"
  match['id']
end

def make_profile(name, bundle_id, cert_id, device_id)
  code, d = api(:get, "/v1/profiles?filter[name]=#{URI.encode_www_form_component(name)}&limit=5")
  (d['data']||[]).each { |p| api(:delete, "/v1/profiles/#{p['id']}"); puts "deleted stale profile #{p['id']}" } if code==200
  body={data:{type:'profiles',attributes:{name:name,profileType:'IOS_APP_DEVELOPMENT'},
    relationships:{bundleId:{data:{type:'bundleIds',id:bundle_id}},
      certificates:{data:[{type:'certificates',id:cert_id}]},
      devices:{data:[{type:'devices',id:device_id}]}}}}
  code, d = api(:post, "/v1/profiles", body)
  raise "create profile #{name} -> #{code} #{d}" unless code==201
  uuid=d['data']['attributes']['uuid']
  FileUtils.mkdir_p(PROFILE_DIR)
  path=File.join(PROFILE_DIR, "#{uuid}.mobileprovision")
  File.binwrite(path, Base64.decode64(d['data']['attributes']['profileContent']))
  puts "profile '#{name}' uuid=#{uuid} -> #{path}"
  {name:name, uuid:uuid}
end

app_bid = ensure_bundle(APP_BID, 'Busymate Mirror Host')
ext_bid = ensure_bundle(EXT_BID, 'Busymate Mirror Broadcast')
dev_id  = ensure_device
cert_id = dev_cert_id
app_p = make_profile(APP_PROF, app_bid, cert_id, dev_id)
ext_p = make_profile(EXT_PROF, ext_bid, cert_id, dev_id)

File.write(File.join(File.dirname(__FILE__),'prov.env'), <<~ENV)
  export APP_PROFILE_NAME=#{app_p[:name]}
  export APP_PROFILE_UUID=#{app_p[:uuid]}
  export EXT_PROFILE_NAME=#{ext_p[:name]}
  export EXT_PROFILE_UUID=#{ext_p[:uuid]}
ENV
puts "\nDONE. wrote prov.env"
