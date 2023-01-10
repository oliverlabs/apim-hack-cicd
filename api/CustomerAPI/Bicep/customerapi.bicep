param dockerimagetag string 
param location string
param name string
param apidefinitionurl string = '' 
@secure()
param db_connectionstring string

// Variable
var appname = 'ca-customerapi'

// existing resources
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2021-09-30-preview' existing = {
  name: 'umi-${name}'
}

resource acr 'Microsoft.ContainerRegistry/registries@2019-12-01-preview' existing = {
  name: 'acr${name}'
}

resource cae 'Microsoft.App/managedEnvironments@2022-03-01' existing = {
  name: 'cae-${name}'
}

resource apim 'Microsoft.ApiManagement/service@2021-08-01' existing = {
  name: 'apim-${name}'
}

resource ca_customerapi 'Microsoft.App/containerApps@2022-03-01' = {
  name: appname                         // Name of the Container App
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}                  
    }
  }
  properties: {
    managedEnvironmentId: cae.id        // reference to the Container Apps Environment that this Container App is going to run in 
    configuration: {
      activeRevisionsMode: 'single'
      ingress: {                  
        external: true                  // Expose an external ingress so yu can reach it from APIM
        targetPort: 80
        allowInsecure: true
        transport: 'auto'
      }
      registries: [
        {
          identity: uami.id             // reference to the managed identity, this is used to authenticate against Azure Container Registry     
          server: acr.properties.loginServer // Azure Container Registry
        }
      ]
      secrets: [
        {
          name: 'dbconnection'
          value: db_connectionstring    // A secret is created based on data from Azure Key vault
        }
      ]
    }
    template: {
      containers: [
        {
          image: '${acr.properties.loginServer}/customerapi:${dockerimagetag}'  // Docker image in ACR with dockerimagetag generated by the GitHub runner
          name: appname                 
          resources: {
            cpu: json('0.25')
            memory: '.5Gi'
          }
          env: [
            {
              name: 'ConnectionStrings__DefaultConnection'
              secretRef: 'dbconnection' // Environment variable that reference to the secret created above
            }
          ]
          
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2021-08-01' = {
  parent: apim                  // Uses the reference to APIM
  name: 'customerapi'
  properties:{
    serviceUrl: 'https://${ca_customerapi.properties.configuration.ingress.fqdn}' // gets the url from Container Apps
    format: 'openapi+json-link'
    value: apidefinitionurl     // Uses the input parameter from the GitHub workflow. 
    displayName: 'Customer API'
    path: 'ch5'
    protocols:[
      'https'
    ]
    apiType:'http'
  }
}

var operation_policy_xml = '''<policies>
<inbound>
        <base />  
</inbound>
<backend>
        <base />
</backend>
<outbound>
        <base />
        <set-header name="myheader" exists-action="append">
          <value>apimhack</value>
        </set-header>
</outbound>
<on-error>
        <base />
</on-error>
</policies>
'''

var api_policy_xml = '''<policies>
<inbound>
        <base />
        <include-fragment fragment-id="RemoveApimKey" />
</inbound>
<backend>
        <base />
</backend>
<outbound>
        <base />
</outbound>
<on-error>
        <base />
</on-error>
</policies>
'''

var remove_apim_key_xml = '''
<fragment>
  <set-header name="Ocp-Apim-Subscription-Key" exists-action="override">
	  <value> </value>
  </set-header>
</fragment>
'''

resource operation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' existing = {
  name: 'get-api-customers'
  parent:api
}

resource api_policy 'Microsoft.ApiManagement/service/apis/policies@2021-08-01' = {
  name: 'policy'
  parent:api
  dependsOn: [
    remove_apim_key
  ]
  properties: {
    value: api_policy_xml
    format: 'xml' 
  }
}

resource operation_policy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  name: 'policy'
  parent:operation
  properties:{
    value: operation_policy_xml
    format: 'xml'
  }

}
resource remove_apim_key 'Microsoft.ApiManagement/service/policyFragments@2021-12-01-preview' = {
  name: 'RemoveApimKey'
  parent: apim
  properties: {
    description: 'Removes the API Management Key from the request'
    format: 'xml'
    value: remove_apim_key_xml
  }
}

