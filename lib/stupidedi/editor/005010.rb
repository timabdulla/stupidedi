module Stupidedi
  module Editor

    #
    # Validates (edits) a "005010" functional groups (GS/GE), then selects the
    # appropriate editor, according to the config, and edits each transaction
    # set (ST/SE)
    #
    class FiftyTenEd < AbstractEd

      # @return [Config]
      attr_reader :config

      # @return [Time]
      attr_reader :received

      def initialize(config, received)
        @config, @received =
          config, received
      end

      def validate(gs, acc)
        acc.tap { edit_gs(gs, acc) }
      end

    private

      def edit_gs(gs, acc)
        # Functional Group Code
        edit(:GS01) do
          gs.element(1).tap do |e|
            if e.node.blank?
              if e.node.usage.required?
                acc.ak905(e, "R", "1", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ak905(e, "R", "1", "must not be present")
            else
              # @todo: The allowed value depends on the child transaction set,
              # but the GS segment is not declared in the transaction set def.
              # Furthermore, the functional group may contain many transaction
              # sets, so we need to check it once we get to the ST segment...
            end
          end
        end

        # Application Sender's Code
        edit(:GS02) do
          gs.element(2).tap do |e|
            if e.node.blank?
              if e.node.usage.required?
                acc.ak905(e, "R", "14", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ak905(e, "R", "14", "must not be present")
            elsif e.node.invalid? or not config.editor.an?(e.node)
              acc.ak905(e, "R", "14", "is not a valid string")
            end
          end
        end

        # Application Receiver's Code
        edit(:GS03) do
          gs.element(3).tap do |e|
            if e.node.blank?
              acc.ak905(e, "R", "13", "must be present")
            elsif e.node.invalid? or not config.editor.an?(e.node)
              acc.ak905(e, "R", "13", "is not a valid string")
            end
          end
        end

        # Date
        edit(:GS04) do
          gs.element(4).tap do |e|
            if e.node.blank?
              acc.ta105(e, "R", "024", "must be present")
            elsif e.node.invalid?
              acc.ta105(e, "R", "024", "is not a valid date")
            elsif e.node > received.utc.send(:to_date)
              acc.ta105(e, "R", "024", "must not be a future date")
            end
          end
        end

        # Time
        edit(:GS05) do
          gs.element(5).tap do |e|
            if e.node.blank?
              acc.ta105(e, "R", "024", "must be present")
            elsif e.node.invalid?
              acc.ta105(e, "R", "024", "is not a valid time")
            else
              gs.element(4).reject{|f| f.node.invalid? }.tap do |f|
                if e.node.to_time(f.node) > received.utc
                  acc.ta105(e, "R", "024", "must not be a future date")
                end
              end
            end
          end
        end

        # Group Control Number
        edit(:GS06) do
          gs.element(6).tap do |e|
            if e.node.blank?
              acc.ak905(e, "R", "6", "must be present")
            elsif e.node.invalid?
              acc.ak905(e, "R", "6", "is not a valid string")
            elsif e.node < 0
              acc.ak905(e, "R", "6", "must be positive")
            elsif e.node > 999_999_999
              acc.ak905(e, "R", "6", "is too long")
            end
          end
        end

        # Responsible Agency Code
        edit(:GS07) do
          gs.element(7).tap do |e|
            if e.node.blank?
              acc.ta105(e, "R", "024", "must be present")
            elsif e.node.invalid?
              acc.ta105(e, "R", "024", "is not a valid string")
            elsif e.node.usage.allowed_values.exclude?(e.node.to_s)
              acc.ta105(e, "R", "024", "is not an allowed value")
            end
          end
        end

        # Version/Release/Industry Identifier Code
        edit(:GS08) do
          gs.element(8).tap do |e|
            if e.node.blank?
              acc.ak905(e, "R", "2", "must be present")
            end
          end
        end

        st, st02s = gs.find!(:ST), Hash.new{|h,k| h[k] = [] }
        # Collect all the ST02 elements within this functional group
        while st.defined?
          st = st.flatmap do |st|
            edit_st(st, acc)

            st.element(2).tap{|e| st02s[e.node.to_s] << e }
            st.find!(:ST)
          end
        end

        edit(:ST) do
          if st02s.empty?
            gs.segment.tap{|s| acc.ik502(s, "R", "1", "missing ST segment") }
          end
        end

        edit(:ST02) do
          st02s.each do |number, es|
            next if number.blank?
            es.tail.each do |e|
              acc.ik502(e, "R", "23", "must be unique within functional group")
            end
          end
        end

        edit(:GE) do
          gs.find(:GE).tap do |ge|
            edit_ge(ge, gs, st02s.length, acc)
          end.explain do
            gs.segment.tap{|s| acc.ak905(s, "R", "3", "missing GE segment") }
          end
        end
      end

      def edit_ge(ge, gs, st_count, acc)
        # Number of Transaction Sets Included
        edit(:GE01) do
          ge.element(1).tap do |e|
            if e.node.empty?
              acc.ak905(e, "R", "5", "must be present")
            elsif e.node.invalid?
              acc.ak905(e, "R", "5", "must be numeric")
            elsif e.node != st_count
              acc.ak905(e, "R", "5", "must equal the number of transactions")
            end
          end
        end

        # Group Control Number
        edit(:GE02) do
          ge.element(2).tap do |e|
            if e.node.empty?
              acc.ak905(e, "R", "4", "must be present")
            else
              gs.element(6).reject{|f| e.node == f.node }.tap do |f|
                acc.ak905(e, "R", "4", "must match functional group header control number")
              end
            end
          end
        end
      end

      def edit_st(st, acc)
        st.segment.tap do |x|
          unless x.node.invalid?
            # Invoke a general transaction set editor, which will later
            # dispatch to a guide-specific transaction set editor
            editor = TransactionSetEd.new(config, received)
            editor.validate(st, acc)
          else
            acc.ik502(x, "R", "I6", x.node.reason)
            return
          end
        end

        # Transaction Set Identifier Code
        edit(:ST01) do
          st.element(1).tap do |e|
            if e.node.blank?
              if e.node.usage.required?
                acc.ik502(e, "R", "6", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ik502(e, "R", "6", "must not be present")
            elsif e.node.invalid?
              acc.ik502(e, "R", "6", "is not a valid identifier")
            elsif e.node.usage.allowed_values.exclude?(e.node.to_s)
              acc.ik502(e, "R", "6", "is not an allowed value")
            end
          end
        end

        # Transaction Set Control Number
        edit(:ST02) do
          st.element(2).tap do |e|
            if e.node.blank?
              if e.node.usage.required?
                acc.ik502(e, "R", "7", "must be present")
              elsif e.node.usage.forbidden?
                acc.ik502(e, "R", "7", "must not be present")
              elsif e.node.invalid?
                acc.ik502(e, "R", "7", "is not a valid string")
              end
            end
          end
        end

        # Implementation Convention Reference
        edit(:ST03) do
          st.element(3).tap do |e|
            if e.node.blank?
              if e.node.usage.required?
                acc.ik502(e, "R", "I6", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ik502(e, "R", "I6", "must not be present")
            elsif e.node.invalid?
              acc.ik502(e, "R", "I6", "is not a valid string")
            elsif e.node.usage.allowed_values.exclude?(e.node.to_s)
              acc.ik502(e, "R", "I6", "is not an allowed value")
            end
          end
        end

        edit(:SE) do
          st.find(:SE).tap do |se|
            edit_se(se, st, acc)
          end.explain do
            st.segment.tap{|s| acc.ik502(s, "R", "2", "missing SE segment") }
          end
        end
      end

      def edit_se(se, st, acc)
        # Number of Included Segments
        edit(:SE01) do
          se.element(1).tap do |e|
            if e.node.empty?
              if e.node.usage.required?
                acc.ik502(e, "R", "4", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ik502(e, "R", "4", "must not be present")
            elsif e.node.invalid?
              acc.ik502(e, "R", "4", "must be numeric")
            else
              st.distance(se).tap do |d|
                unless e.node == d + 1
                  acc.ik502(e, "R", "4", "must equal the transaction segment count")
                end
              end
            end
          end
        end

        # Transaction Set Control Number
        edit(:SE02) do
          se.element(2).tap do |e|
            if e.node.empty?
              if e.node.usage.required?
                acc.ik502(e, "R", "3", "must be present")
              end
            elsif e.node.usage.forbidden?
              acc.ik502(e, "R", "3", "must not be present")
            elsif e.node.invalid?
              acc.ik502(e, "R", "3", "is not a valid string")
            else
              st.element(2).reject{|f| f.node == e.node }.tap do
                acc.ik502(e, "R", "3", "must equal transaction header control number")
              end
            end
          end
        end
      end

    end

  end
end