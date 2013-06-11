class CreateDataValues < ActiveRecord::Migration
  def self.up
    create_table :data_values do |t|
      t.string :key
      t.string :data_value
      t.timestamps
    end
  end

  def self.down
    drop_table :data_values
  end
end