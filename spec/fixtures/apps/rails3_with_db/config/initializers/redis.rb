if ENV['VCAP_SERVICES']
  services = JSON.parse(ENV['VCAP_SERVICES'])
  if services
    redis_service = nil
    services.each do |k, v|
      v.each do |s|
        if k.split('-')[0].downcase == 'redis'
          redis_service = s["credentials"]
        end
      end
    end
    if redis_service
      $redis = Redis.new({:host => redis_service["hostname"], :port => redis_service["port"], :password => redis_service["password"]})
    end
  end
end
