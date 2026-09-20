# frozen-string-literal: true

module TagLib
  module Version
    MAJOR = 2
    MINOR = 3
    PATCH = 2
    BUILD = 3

    STRING = [MAJOR, MINOR, PATCH, BUILD].compact.join('.')
  end
end
