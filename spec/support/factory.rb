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
      "credentials" => { "user" => "password" },
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

      "runtime_name"        => "ruby19",
      "framework_name"      => "rails",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => [valid_service_attributes],
      "flapping"            => false,
    }
  end
end
