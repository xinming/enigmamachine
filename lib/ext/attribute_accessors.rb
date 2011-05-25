class Class
  def cattr_reader(*syms)
    options = syms.extract_options!
    syms.each do |sym|
      class_eval(<<-EOS, __FILE__, __LINE__ + 1)
        unless defined? @@#{sym}
          @@#{sym} = nil
        end

        def self.#{sym}
          @@#{sym}
        end
      EOS

      unless options[:instance_reader] == false
        class_eval(<<-EOS, __FILE__, __LINE__ + 1)
          def #{sym}
            @@#{sym}
          end
        EOS
      end
    end
  end

  def cattr_writer(*syms)
    options = syms.extract_options!
    syms.each do |sym|
      class_eval(<<-EOS, __FILE__, __LINE__ + 1)
        unless defined? @@#{sym}
          @@#{sym} = nil
        end

        def self.#{sym}=(obj)
          @@#{sym} = obj
        end
      EOS

      unless options[:instance_writer] == false
        class_eval(<<-EOS, __FILE__, __LINE__ + 1)
          def #{sym}=(obj)
            @@#{sym} = obj
          end
        EOS
      end
      self.send("#{sym}=", yield) if block_given?
    end
  end

  def cattr_accessor(*syms, &blk)
    cattr_reader(*syms)
    cattr_writer(*syms, &blk)
  end
end