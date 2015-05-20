require 'marathon_deploy/http_util'
require 'marathon_deploy/utils'
require 'marathon_deploy/marathon_defaults'
require 'timeout'

class Deployment
  
  DEPLOYMENT_RECHECK_INTERVAL = MarathonDefaults::DEPLOYMENT_RECHECK_INTERVAL
  DEPLOYMENT_TIMEOUT = MarathonDefaults::DEPLOYMENT_TIMEOUT
  HEALTHY_WAIT_TIMEOUT = MarathonDefaults::HEALTHY_WAIT_TIMEOUT
  HEALTHY_WAIT_RECHECK_INTERVAL = MarathonDefaults::HEALTHY_WAIT_RECHECK_INTERVAL
  
  attr_reader :url, :application, :deploymentId
  
  def initialize(url, application)
    raise ArgumentError, "second argument to deployment object must be an Application", caller unless (!application.nil? && application.class == Application)
    raise Error::BadURLError, "invalid url => #{url}", caller if (!HttpUtil.valid_url(url))    
    @url = HttpUtil.clean_url(url)
    @application = application
  end
  
  def timeout
    return DEPLOYMENT_TIMEOUT
  end
  
  def healthcheck_timeout
    return HEALTHY_WAIT_TIMEOUT
  end
  
  def versions  
    if (!applicationExists?)  
      response = HttpUtil.get(@url + MarathonDefaults::MARATHON_APPS_REST_PATH + @application.id + '/versions')  
      response_body = Utils.response_body(response)
      return response_body[:versions]
    else
      return Array.new
    end
  end
     
  def wait_for_deployment_id(message = "Deployment with deploymentId #{@deploymentId} in progress")
      startTime = Time.now
      deployment_seen = false  
      Timeout::timeout(DEPLOYMENT_TIMEOUT) do
        while running_for_deployment_id?

          deployment_seen = true
          #response = list_all
          #STDOUT.print "." if ( $LOG.level == 1 )
          elapsedTime = '%.2f' % (Time.now - startTime)
          $LOG.info(message + " (elapsed time #{elapsedTime}s)")
          deployments = deployments_for_deployment_id
          deployments.each do |item|
            $LOG.debug(deployment_string(item))
          end   
          sleep(DEPLOYMENT_RECHECK_INTERVAL)
        end        
        #STDOUT.puts "" if ( $LOG.level == 1 )
        if (deployment_seen)
          elapsedTime = '%.2f' % (Time.now - startTime)
          $LOG.info("Deployment with deploymentId #{@deploymentId} ended (Total time #{elapsedTime}s )")  
        end
      end    
  end
  
  def wait_for_application(message = "Deployment of application #{@application.id} in progress")
      deployment_seen = false  
      Timeout::timeout(DEPLOYMENT_TIMEOUT) do
        while running_for_application_id?
          deployment_seen = true
          #response = list_all
          #STDOUT.print "." if ( $LOG.level == 1 )
          $LOG.info(message)
          deployments_for_application_id.each do |item|
            $LOG.debug(deployment_string(item))
          end
          #$LOG.debug(JSON.pretty_generate(JSON.parse(response.body)))       
          sleep(DEPLOYMENT_RECHECK_INTERVAL)
        end                
        #STDOUT.puts "" if ( $LOG.level == 1 )
        if (deployment_seen)
          $LOG.info("Deployment of application #{@application.id} ended")  
        end
      end    
  end
  
  def wait_until_healthy    
    Timeout::timeout(HEALTHY_WAIT_TIMEOUT) do
      loop do
        break if (!health_checks_defined?)
        sick = get_alive("false")
        if (!sick.empty?)
          $LOG.info("#{sick.size}/#{@application.instances} instances are not healthy => " + sick.join(','))
        else
          healthy = get_alive("true")
          if (healthy.size == @application.instances)
            $LOG.info("#{healthy.size}/#{@application.instances} instances are healthy => " + healthy.join(','))
            break
          else
            $LOG.info("#{healthy.size}/#{@application.instances} healthy instances seen, retrying")
          end
        end      
        sleep(HEALTHY_WAIT_RECHECK_INTERVAL)
      end                         
    end  
  end
    
  def cancel(deploymentId,force=false)
    raise Error::BadURLError, "deploymentId must be specified to cancel deployment", caller if (deploymentId.empty?)
    if (running_for_deployment_id?(deploymentId))
      response = HttpUtil.delete(@url + MarathonDefaults::MARATHON_DEPLOYMENT_REST_PATH + deploymentId + "?force=#{force}")
      $LOG.debug("Cancellation response [#{response.code}] => " + JSON.pretty_generate(JSON.parse(response.body)))
    end
    return response
  end
  
  def applicationExists?
    response = list_app
    if (response.code.to_i == 200)
      return true
    end
      return false
  end
       
  def create_app
    response = HttpUtil.post(@url + MarathonDefaults::MARATHON_APPS_REST_PATH,@application.json)
    @deploymentId = get_deployment_id
    return response
  end
  
  def update_app(force=false)
    url = @url + MarathonDefaults::MARATHON_APPS_REST_PATH + @application.id
    url += force ? '?force=true' : ''
    $LOG.debug("Updating app #{@application.id}  #{url}")
    response = HttpUtil.put(url,@application.json)    
    @deploymentId = Utils.response_body(response)[:deploymentId]
    return response
    
  end
  
  def rolling_restart
    url = @url + MarathonDefaults::MARATHON_APPS_REST_PATH + @application.id + '/restart'
    $LOG.debug("Calling marathon api with url: #{url}") 
    response = HttpUtil.post(url,{})
    $LOG.info("Restart of #{@application.id} returned status code: #{response.code}")
    $LOG.info(JSON.pretty_generate(JSON.parse(response.body)))
  end    
  
  ####### PRIVATE METHODS ##########
  private

  def get_alive(value)        
    state = Array.new
    
    if (health_checks_defined?)     
      response = list_app
      response_body = Utils.response_body(response)
        if (response_body[:app].empty?)
          raise Error::DeploymentError, "Marathon returned an empty app json object", caller
        else
          get_healthcheck_results.flatten.each do |result|
            next if result.nil?
            alive = result[:alive].to_s
            taskId = result[:taskId].to_s              
            if (!alive.nil? && !taskId.nil?)
              state << taskId if (alive == value)
            end          
          end         
        end
    else
      $LOG.info("No health checks defined. Cannot determine application health of #{@application.id}.")    
    end
    return state
  end
  
  def get_task_ids
    response = list_app
    response_body = Utils.response_body(response)
    return response_body[:app][:tasks].collect { |task| task[:id]}
  end
  
  def get_healthcheck_results
    response = list_app
    response_body = Utils.response_body(response)
    return response_body[:app][:tasks].collect { |task| task[:healthCheckResults]}
  end
  
  def health_checks_defined?
    response = list_app
    response_body = Utils.response_body(response)
    return response_body[:app][:healthChecks].size == 0 ? false : true
  end
  
  def get_deployment_id
    response = list_app
    payload = Utils.response_body(response)
    return payload[:app][:deployments].first[:id] unless (payload[:app].nil?)
    return nil
  end
    
  def list_all
    HttpUtil.get(@url + MarathonDefaults::MARATHON_DEPLOYMENT_REST_PATH)
  end 
  
  def running_for_application_id?
    if (deployment_running? && !deployments_for_application_id.empty?)
      return true
    end
      return false
  end
  
  def running_for_deployment_id?
    if (deployment_running? && !deployments_for_deployment_id.empty?)
      return true
    end
      return false
  end
  
  def deployment_running?
    response = list_all
    body = JSON.parse(response.body)
    return false if body.empty?
    return true
  end   
   
  def get_deployment_ids
    response = list_all
    payload = JSON.parse(response.body)
    return payload.collect { |d| d['id'] }
  end
  
  def list_app
    HttpUtil.get(@url + MarathonDefaults::MARATHON_APPS_REST_PATH + @application.id)
  end
  
  # DONT USE: the response seems to be broken in marathon for /v2/apps/application-id/tasks
  #def get_tasks
  #  HttpUtil.get(@url + MarathonDefaults::MARATHON_APPS_REST_PATH + @application.id + '/tasks')
  #end
  
  def deployment_string(deploymentJsonObject)  
    string = "\n" + "+-" * 25 + " DEPLOYMENT INFO  " + "+-" * 25 + "\n"
    deploymentJsonObject.sort.each do |k,v|
      case v
      when String
        string += k + " => " + v + "\n"
      when Fixnum
        string += k + " => " + v.to_s + "\n"
      when Array
        string += k + " => " + v.join(',') + "\n"
      else
        string += "#{k} + #{v}\n"
      end
    end  
   return string 
  end
    
  def deployments_for_deployment_id
    response = list_all
    payload = JSON.parse(response.body)
    return payload.find_all { |d| d['id'] == @deploymentId }
  end
  
  def deployments_for_application_id
    response = list_all
    payload = JSON.parse(response.body)
    return payload.find_all { |d| d['affectedApps'].include?('/' + @application.id) }
  end
  
end