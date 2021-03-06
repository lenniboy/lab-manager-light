  
window.lml = window.lml || {};


window.lml.MainController = function MainController($scope,$log,AjaxCallService) {
  $scope.globals = {activeTab : "vm_overview"};
  $scope.isServerRequestRunning = false;
  $scope.setServerRequestRunning = function setWaitingStatus(status){
    $scope.isServerRequestRunning = status;
  };
  $scope.version="";

  	AjaxCallService.sendAjaxCall('api/version.pl',{}, function successCallback(data){
		$log.info("Received lml version: ",data.version);
		$scope.version = data.version;
		$scope.setServerRequestRunning(false);
	}, function errorCallback(){
	   $scope.setServerRequestRunning(false);
	});

};

