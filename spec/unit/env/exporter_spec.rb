require "spec_helper"
require "dea/env/exporter"

module Dea
  class Env
    describe Exporter do
      subject(:env_exporter) { Exporter.new(variables) }

      context "with a single value" do
        let(:variables) { [[:a, 1]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="1";\n})
        end
      end

      context "with a dollar signs" do
        let(:variables) { [[:a, '$potato']] }

        it "doesn't escape them" do
          expect(env_exporter.export).to eql(%Q{export a="$potato";\n})
        end
      end

      context "with a dollar signs on VCAP_SERVICES" do
        let(:variables) { [["VCAP_SERVICES", '$potato']] }

        it "escapes them" do
          expect(env_exporter.export).to eql(%Q{export VCAP_SERVICES=\\$potato;\n})
        end
      end

      context "with a dollar signs on VCAP_APPLICATION" do
        let(:variables) { [["VCAP_APPLICATION", '$potato']] }

        it "escapes them" do
          expect(env_exporter.export).to eql(%Q{export VCAP_APPLICATION=\\$potato;\n})
        end
      end

      context "with a dollar signs on DATABASE_URL" do
        let(:variables) { [["DATABASE_URL", 'postgres://jim:$uper@database.com']] }

        it "escapes them" do
          expect(env_exporter.export).to eq(%Q{export DATABASE_URL=postgres://jim:\\$uper@database.com;\n})
        end
      end

      context 'with a nil value for DATABASE_URL, VCAP_SERVICES, or VCAP_APPLICATION' do
        let(:variables) { [["DATABASE_URL", nil], ["VCAP_APPLICATION", nil], ["VCAP_SERVICES", nil]] }

        it 'does not export any variables' do
          expect(env_exporter.export).to eq(%Q{export DATABASE_URL='';\nexport VCAP_APPLICATION='';\nexport VCAP_SERVICES='';\n})
        end
      end

      context "with multiple values" do
        let(:variables) { [["a", 1], ["b", 2]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="1";\nexport b="2";\n})
        end
      end

      context "with value containing quotes" do
        let(:variables) { [["a", %Q{"1'}]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="\\"1'";\n})
        end
      end

      context "with non-string values" do
        let(:variables) { [[:a, :b]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="b";\n})
        end
      end

      context "with spaces in values" do
        let(:variables) { [[:a, "one two"]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="one two";\n})
        end
      end

      context "with = in values" do
        let(:variables) { [[:a, "one=two"]] }

        it "exports the variables" do
          expect(env_exporter.export).to eql(%Q{export a="one=two";\n})
        end
      end

      context "when they reference each other in other in order" do
        let(:variables) { [["x", "bar"], ["foo", "$x"]] }

        context "when evaluated by bash" do
          let(:evaluated_env) { `#{env_exporter.export} env` }

          it "substitutes the reference" do
            expect(evaluated_env).to include("x=bar")
            expect(evaluated_env).to include("foo=bar")
          end
        end
      end
    end
  end
end
