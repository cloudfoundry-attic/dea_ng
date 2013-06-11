class MongoDataValue
  include MongoMapper::Document
  key :name, :type => String
  key :email, :type => String
end