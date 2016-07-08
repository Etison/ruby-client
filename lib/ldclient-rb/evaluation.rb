module LaunchDarkly

  module Evaluation
    include Operators
    BUILTINS = [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]

    class EvaluationError < StandardError
    end

    # Evaluates a feature flag, returning a hash containing the evaluation result and any events
    # generated during prerequisite evaluation. Raises EvaluationError if the flag is not well-formed
    # Will return nil, but not raise an exception, indicating that the rules (including fallthrough) did not match
    # In that case, the caller should return the default value.
    def evaluate(flag, user, store)
      if flag.nil?
        raise EvaluationError, "Flag does not exist"
      end

      if user.nil? || user[:key].nil?
        raise EvaluationError, "Invalid user"
      end

      events = []

      if flag[:on]
        res = eval_internal(flag, user, store, events)

        return res if !res[:value].nil?
      end

      if !flag[:offVariation].nil? && flag[:offVariation] < flag[:variations].length
        value = flag[:variations][flag[:offVariation]]
        return {value: value, events: events}
      end

      {value: nil, events: events}
    end

    def eval_internal(flag, user, store, events)
      failed_prereq = false
      # Evaluate prerequisites, if any
      if !flag[:prerequisites].nil?
        flag[:prerequisites].each do |prerequisite|

          prereq_flag = store.get(prerequisite[:key])

          if !prereq_flag[:on]
            failed_prereq = true
          end

          begin
            prereq_res = eval_internal(prereq_flag, user, store, events)
            events.push(kind: "feature", key: prereq_flag[:key], value: default, default: default)
            variation = get_variation(prereq_flag, prerequisite[:variation])
            if prereq_res.nil? || prereq_res != variation
              failed_prereq = true
            end
          rescue => exn
            @config.logger.error("[LDClient] Error evaluating prerequisite: #{exn.inspect}")
            failed_prereq = true
          end

        end

        if failed_prereq
          return {value: nil, events: events} 
        end
      end
      # The prerequisites were satisfied.
      # Now walk through the evaluation steps and get the correct
      # variation index
      {value: eval_rules(flag, user), events: events}
    end

    def eval_rules(flag, user)
      # Check user target matches
      @config.logger.debug("Checking user target matches for #{flag[:targets]}")

      if !flag[:targets].nil?
        flag[:targets].each do |target|
          if !target[:values].nil?
            target[:values].each do |value|
              return get_variation(flag, target[:variation]) if value == user[:key]
            end
          end
        end
      end  

      @config.logger.debug("Checking custom rule matches for #{flag[:rules]}")

      # Check custom rules
      if !flag[:rules].nil?
        flag[:rules].each do |rule|
          return variation_for_user(rule, user, flag) if rule_match_user(rule, user)
        end
      end

      @config.logger.debug("Checking fallthrough rule for #{flag[:fallthrough]}")


      # Check the fallthrough rule
      if !flag[:fallthrough].nil?
        return variation_for_user(flag[:fallthrough], user, flag)
      end

      # Not even the fallthrough matched-- return the off variation or default
      nil
    end

    def get_variation(flag, index)
      if index >= flag[:variations].length
        raise EvaluationError, "Invalid variation index"
      end
      flag[:variations][index]
    end

    def rule_match_user(rule, user)
      return false if !rule[:clauses]

      @config.logger.debug("Checking clauses for #{rule[:clauses]}")

      rule[:clauses].each do |clause|
        @config.logger.debug("Checking claus for #{clause}")
        return false if !clause_match_user(clause, user)
      end

      return true
    end

    def clause_match_user(clause, user)
      val = user_value(user, clause[:attribute])
      return false if val.nil?

      @config.logger.debug("Got user value #{val} for #{clause[:attribute]} and user #{user}")

      op = Operators::operators[clause[:op]]

      if val.is_a? Enumerable
        @config.logger.debug("User value #{val} is enumerable")
        val.each do |v|
          return maybe_negate(clause, true) if match_any(op, v, clause[:values])
        end
        return maybe_negate(clause, false)
      end

      @config.logger.debug("Checking whether #{val} matches #{clause[:values]}")
      maybe_negate(clause, match_any(op, val, clause[:values]))
    end    

    def variation_for_user(rule, user, flag)
      if !rule[:variation].nil? # fixed variation
        return get_variation(flag, rule[:variation])
      elsif !rule[:rollout].nil? # percentage rollout
        rollout = rule[:rollout]
        bucket_by = rollout[:bucketBy].nil? ? "key" : rollout[:bucketBy]
        bucket = bucket_user(user, flag[:key], bucket_by, flag[:salt])
        sum = 0;
        rollout[:variations].each do |variate|
          sum += variate[:weight].to_f / 100000.0
          return get_variation(flag, variate[:variation]) if bucket < sum
        end
        nil
      else # the rule isn't well-formed
        raise EvaluationError, "Rule does not define a variation or rollout"
      end
    end

    def bucket_user(user, key, bucket_by, salt)
      return nil unless user[:key]

      id_hash = user_value(user, bucket_by)

      if user[:secondary]
        id_hash += "." + user[:secondary]
      end

      hash_key = "%s.%s.%s" % [key, salt, id_hash]

      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)      
    end

    def user_value(user, attribute)
      attribute = attribute.to_sym
      @config.logger.debug("Checking user value for user #{user} and attribute #{attribute}")

      if BUILTINS.include? attribute
        user[attribute]
      elsif !user[:custom].nil?
        user[:custom][attribute]
      else
        nil
      end
    end

    def maybe_negate(clause, b)
      clause[:negate] ? !b : b
    end

    def match_any(op, value, values)
      values.each do |v|
        return true if op.call(value, v)
      end
      return false
    end
  end

end
