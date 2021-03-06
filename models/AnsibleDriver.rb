# Generates response
def r **result
  JSON.pretty_generate result
end

# Checks permissions for given playbook and action for given user
def ansible_check_permissions pb, u, uma
  u.info!
  perm = pb['extra_data']['PERMISSIONS'].split('')
  mod = perm.values_at(*Array.new(3) { |i| uma + 3 * i }).map { | value | value == '1' ? true : false }
  return (
    (u.id == pb['uid'] && mod[0]) ||
    (u.groups.include?(pb['gid']) && mod[1]) ||
    (mod[2]) ||
    (u.groups.include?(0))
  )
end

class String
  def is_json? # Checks if this string is JSON parsable
    begin
      JSON.parse self
      true
    rescue
      false
    end
  end
end

class AnsiblePlaybookModel
  attr_reader :method, :id
  attr_accessor :body

  # Each number is corresponds to position at ACTIONS
  RIGHTS = {
    'chown'  => 2,
    'chgrp'  => 2,
    'chmod'  => 2,
    'run'    => 0,
    'update' => 1,
    'delete' => 2,
    'vars'   => 0,
    'clone'  => 0,
    'rename' => 1
  }

  ACTIONS = ['USE', 'MANAGE', 'ADMIN']

  def initialize id: nil, data: { 'action' => { 'params' => {} } }, user: nil
    @user = user # Need this to check permissions later
    @user.info!
    if id.nil? then # If id is not given - new Playbook will be created
      @params = data
      begin
        # Check if mandatory params are not nil
        check = @params['name'].nil? ||
                @params['body'].nil? ||
                @params['extra_data'].nil? ||
                @params['extra_data']['PERMISSIONS'].nil?
      rescue
        raise ParamsError.new @params # Custom error if extra_data is nil
      end
      raise ParamsError.new(@params) if check # Custom error if something is nil
      raise NoAccessError.new(2) unless @user.groups.include? 0 # Custom error if user is not in oneadmin group

      @id = AnsiblePlaybook.new(**@params.to_sym!.merge({ uid: @user.id, gid: @user.gid })).id # Save id of new playbook
    else # If id is given getting existing playbook
      # Params from OpenNebula are always in {"action" => {"perform" => <%method name%>, "params" => <%method params%>}} form
      # So here initializer saves method and params to object
      @method, @params = data['action']['perform'], data['action']['params']
      @body = IONe.new($client, $db).GetAnsiblePlaybook(@id = id) # Getting Playbook in hash form
      @permissions = Array.new(3) { |uma| ansible_check_permissions(@body, @user, uma) } # Parsing permissions

      raise NoAccessError.new(0) unless @permissions[0] # Custom error if user has no USE rights
    end
  end

  # Calls API method given to initializer
  def call
    access = RIGHTS[method] # Checking access permissions for perform corresponding ACTION
    raise NoAccessError.new(access) unless @permissions[access] # Raising Custom error if no access granted

    send(@method) # Calling method from @method
  end

  # Clones Playbook with given id to a new playbook with given name in params
  def clone
    args = @body
    args.delete('id')
    IONe.new($client, $db).CreateAnsiblePlaybook(
      args.merge({
                   :name => @params["name"], :uid => @user.id, :gid => @user.gid
                 })
    )
  end

  # Updated Playbook with given keys and values. If params are {"name" => "new_name"}, key "name" will have value "new_name" after Update performed
  def update
    @params.each do |key, value| # Changing each key
      @body[key] = value
    end

    IONe.new($client, $db).UpdateAnsiblePlaybook @body # Updating playbook with resulting body
    nil
  end

  # Deletes Playbook with id
  def delete
    IONe.new($client, $db).DeleteAnsiblePlaybook @id
    nil
  end

  # Changes Playbook owner
  def chown
    # if chown or chgrp method called OpenNebula always calling chown.
    # And if owner or group is not changing, it sets corresponding key to "-1".
    # So if owner is set to "-1" chown will try to call chgrp
    IONe.new($client, $db).UpdateAnsiblePlaybook("id" => @body['id'], "uid" => @params['owner_id']) unless @params['owner_id'] == '-1'
    chgrp unless @params['group_id'] == '-1' # But if group is also set to "-1", nothing will be called if so
    nil
  end

  # Changes Playbook group
  def chgrp
    IONe.new($client, $db).UpdateAnsiblePlaybook("id" => @body['id'], "gid" => @params['group_id'])
    nil
  end

  # Changes Playbook permissions table by changing extra_data => PERMISSIONS
  def chmod
    raise ParamsError.new(@params) if @params.nil? # PERMISSIONS cannot be nil, but database not checking this

    IONe.new($client, $db).UpdateAnsiblePlaybook("id" => @body['id'], "extra_data" => @body['extra_data'].merge("PERMISSIONS" => @params))
    nil
  end

  # Renames Playbook
  def rename
    IONe.new($client, $db).UpdateAnsiblePlaybook("id" => @body['id'], "name" => @params['name'])
    nil
  end

  # Returns Variabled defined at Playbook body
  def vars
    IONe.new($client, $db).GetAnsiblePlaybookVariables @id
  end

  # Creates install process from given Playbook with given hosts and vars
  def to_process
    IONe.new($client, $db).AnsiblePlaybookToProcess(@body['id'], @params['hosts'], 'default', @params['vars'])
  end

  class NoAccessError < StandardError # Custom error for no access exceptions. Returns string contain which action is blocked
    def initialize action
      super()
      @action = AnsiblePlaybookModel::ACTIONS[action]
    end

    def message
      "Not enough rights to perform action: #{@action}!"
    end
  end

  class ParamsError < StandardError # Custom error for not valid params, returns given params inside
    def initialize params
      super()
      @params = params
    end

    def message
      "Some arguments are missing or nil! Params:\n#{@params.inspect}"
    end
  end
end

class AnsiblePlaybookProcessModel
  RIGHTS = {
    'run' => 1,
    'delete' => 2
  }

  attr_reader :method, :id
  attr_accessor :body

  def initialize id: nil, data: { 'action' => {} }, user: nil
    @user = user # Need this to check permissions later
    if id.nil? then # If id is not given - new Playbook will be created
      @params = data
      begin
        # Check if mandatory params are not nil
        check = @params['playbook_id'].nil? || @params['hosts'].nil?
      rescue
        raise ParamsError.new @params # Custom error if extra_data is nil
      end
      raise ParamsError.new(@params) if check # Custom error if something is nil

      raise NoAccessError.new(2) unless user.groups.include? 0 # Custom error if user is not in oneadmin group

      @user.info! # Retrieve object body
      @id = IONe.new($client, $db).AnsiblePlaybookToProcess( # Save id of new playbook
        @params['playbook_id'], @user.id, @params['hosts'], @params['vars'], @params['comment']
      )
    else # If id is given getting existing playbook
      # Params from OpenNebula are always in {"action" => {"perform" => <%method name%>, "params" => <%method params%>}} form
      # So here initializer saves method and params to object
      @method, @params = data['action']['perform'], data['action']['params']
      @body = IONe.new($client, $db).GetAnsiblePlaybookProcess(@id = id) # Getting Playbook in hash form
      @permissions = Array.new(3) do |uma|
        ansible_check_permissions({ 'uid' => @body['uid'], 'extra_data' => { 'PERMISSIONS' => '111000000' } }, @user, uma)
      end # Parsing permissions
      raise NoAccessError.new(0) unless @permissions[0] # Custom error if user has no USE rights
    end
  end

  # Calls API method given to initializer
  def call
    access = RIGHTS[method] # Checking access permissions for perform corresponding ACTION
    raise NoAccessError.new(access) unless @permissions[access] # Raising Custom error if no access granted

    send(@method) # Calling method from @method
  end

  def run
    IONe.new($client, $db).RunAnsiblePlaybookProcess(@id)
    nil
  end

  def delete
    IONe.new($client, $db).DeleteAnsiblePlaybookProcess(@id)
  end

  # Custom error for no access exceptions. Returns string contain which action is blocked
  class NoAccessError < StandardError
    def initialize action
      super()
      @action = AnsiblePlaybookModel::ACTIONS[action]
    end

    def message
      "Not enough rights to perform action: #{@action}!"
    end
  end

  # Custom error for not valid params, returns given params inside
  class ParamsError < StandardError
    def initialize params
      super()
      @params = params
    end

    def message
      "Some arguments are missing or nil! Params:\n#{@params.inspect}"
    end
  end
end
