require 'marathon_deploy/utils'
require 'logger'

module MarathonDefaults
 
  PRODUCTION_ENVIRONMENT_NAME = 'PRODUCTION'
  DEFAULT_ENVIRONMENT_NAME = 'INTEGRATION'
  DEFAULT_PREPRODUCTION_MARATHON_ENDPOINTS = ['http://192.168.59.103:8080']
  DEFAULT_PRODUCTION_MARATHON_ENDPOINTS = ['http://192.168.59.103:8080']
  DEFAULT_DEPLOYFILE = 'deploy.yaml'
  DEFAULT_LOGFILE = false
  DEFAULT_LOGLEVEL = Logger::INFO

  @@preproduction_override = {
    :instances => 20,
    :mem => 512,
    :cpus => 0.1      
  } 
  
  @@preproduction_env = {
    :DATACENTER_NUMBER => "44",
    :JAVA_XMS => "64m",
    :JAVA_XMX => "128m"
  }  
  
  @@required_marathon_env_variables = %w[
    DATACENTER_NUMBER
    APPLICATION_NAME
  ]
  
  #@@required_marathon_attributes = %w[id env container healthChecks args].map(&:to_sym)
  @@required_marathon_attributes = %w[id].map(&:to_sym)
   
  def self.missing_attributes(json)
    json = Utils.symbolize(json)
    missing = []
    @@required_marathon_attributes.each do |att|
      if (!json[att])
        missing << att 
      end
    end
    return missing
  end
  
  def self.missing_envs(json)
    json = Utils.symbolize(json)
    
    if (!json.key?(:env))
      $LOG.error("no env attribute found in deployment file") 
      exit!
    end
    
    missing = []
    @@required_marathon_env_variables.each do |variable|
      if (!json[:env][variable])
        missing << variable 
      end
    end
    return missing
  end  
  
  def self.overlay_preproduction_settings(json)
    json = Utils.deep_symbolize(json)
      @@preproduction_override.each do |property,value|
        given_value = json[property]
        if (given_value > @@preproduction_override[property])
          $LOG.debug("Overriding property [#{property}: #{json[property]}] with preproduction default [#{property}: #{@@preproduction_override[property]}]")
          json[property] = @@preproduction_override[property]
        end
      end
      @@preproduction_env.each do |name,value|
        json[:env][name] = value
      end
      return json
  end
  
end