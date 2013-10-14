# coding: UTF-8

module Helpers
  def valid_service_attributes
    {
      "name"        => "name",
      "type"        => "type",
      "label"       => "label",
      "vendor"      => "vendor",
      "version"     => "version",
      "tags"        => ["tag1", "tag2"],
      "plan"        => "plan",
      "plan_option" => "plan_option",
      "credentials" => {
        "jdbcUrl" => "jdbc:mysql://some_user:some_password@some-db-provider.com:3306/db_name",
        "uri" => "mysql://some_user:some_password@some-db-provider.com:3306/db_name",
        "name" => "db_name",
        "hostname" => "some-db-provider.com",
        "port" => "3306",
        "username" => "some_user",
        "password" => "some_password"
      },
    }
  end

  def valid_instance_attributes
    {
      "cc_partition"        => "partition",

      "instance_id"         => VCAP.secure_uuid,
      "instance_index"      => 37,

      "application_id"      => "37",
      "application_version" => "some_version",
      "application_name"    => "my_application",
      "application_uris"    => ["foo.com", "bar.com"],

      "droplet_sha1"        => "deadbeef",
      "droplet_uri"         => "http://foo.com/file.ext",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => [valid_service_attributes],
      "flapping"            => false,
    }
  end

  def valid_staging_attributes
    {
      "properties" => {
        "services" => [],
        "resources" => {
          "memory" => 128,
          "disk" => 128,
          "fds" => 5000,
        }
      },
      "app_id" => "app-guid",
      "task_id" => VCAP.secure_uuid,
      "download_uri" => "http://127.0.0.1:12346/download",
      "upload_uri" => "http://127.0.0.1:12346/upload",
      "staged_path" => ""
    }
  end
end
