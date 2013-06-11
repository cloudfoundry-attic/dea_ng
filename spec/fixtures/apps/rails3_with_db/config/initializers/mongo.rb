if ENV['VCAP_SERVICES']
  services = JSON.parse(ENV['VCAP_SERVICES'])
  if services
    mongodb_service = nil
    services.each do |k, v|
      v.each do |s|
        if k.split('-')[0].downcase == 'mongodb'
          mongodb_service = s["credentials"]
        end
      end
    end
    if mongodb_service
      MongoMapper.connection = Mongo::Connection.new(mongodb_service['hostname'], mongodb_service['port'])
      MongoMapper.database = mongodb_service['db']
      MongoMapper.database.authenticate(mongodb_service['username'], mongodb_service['password'])
    end
  end
end
