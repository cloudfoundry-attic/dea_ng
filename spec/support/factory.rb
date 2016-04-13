# coding: UTF-8

module Helpers
  def valid_service_attributes(syslog_drain_url = nil)
    {
      "name"        => "name",
      "type"        => "type",
      "label"       => "label",
      "vendor"      => "vendor",
      "version"     => "version",
      "tags"        => ["tag1", "tag2"],
      "plan"        => "plan",
      "plan_option" => "plan_option",
      "syslog_drain_url" => syslog_drain_url,
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

  def valid_instance_attributes(lots_of_services = false)
    {
      "cc_partition"        => "partition",

      "instance_id"         => Dea.secure_uuid,
      "index"      => 42,

      "droplet"      => "37",
      "application_version" => "some_version",
      "application_name"    => "my_application",
      "application_uris"    => ["foo.com", "bar.com"],

      "droplet_sha1"        => "deadbeef",
      "droplet_uri"         => "http://foo.com/file.ext",

      "limits"              => { "mem" => 512, "disk" => 128, "fds" => 5000 },
      "env"                 => ["FOO=BAR"],
      "services"            => lots_of_services ?
          [valid_service_attributes("syslog://log.example.com"), valid_service_attributes, valid_service_attributes("syslog://log2.example.com")] :
          [valid_service_attributes],
      "egress_network_rules" => [],
      "stack" => "my-stack",
    }
  end

  def valid_staging_attributes
    {
      "properties" => {
        "services" => [],
        "environment" => ["FOO=BAR"],
        "resources" => {
          "memory" => 512,
          "disk" => 128,
          "fds" => 5000,
        }
      },
      "app_id" => "app-guid",
      "task_id" => Dea.secure_uuid,
      "download_uri" => "http://127.0.0.1:12346/download",
      "upload_uri" => "http://127.0.0.1:12346/upload",
      "staged_path" => "",
      "start_message" => valid_instance_attributes,
      "admin_buildpacks" => [],
      "egress_network_rules" => [],
      "stack" => "my-stack",
    }
  end
end
