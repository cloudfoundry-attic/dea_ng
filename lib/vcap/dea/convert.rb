module VCAP module Dea end end

module VCAP::Dea::Convert
  def MB_to_bytes(mb)
    mb * (1024 * 1024)
  end

  def bytes_to_MB(bytes)
    (bytes / (1024*1024)).to_i
  end

  def bytes_to_GB(bytes)
    (bytes / (1024*1024*1024)).to_i
  end
end
