function paths = startup()
%STARTUP Configure paths for the active MATLAB workflow without running it.
thisFile = mfilename('fullpath');
mainDir = fileparts(thisFile);
matlabDir = fileparts(mainDir);
projectRoot = fileparts(matlabDir);

addpath(fullfile(projectRoot, 'config'));
paths = matlab_paths();
activeFolders = {'main','ingestion','preprocessing','feature_extraction', ...
    'analysis','visualization','utilities','apps'};
for k = 1:numel(activeFolders)
    addpath(fullfile(matlabDir, activeFolders{k}));
end
end
