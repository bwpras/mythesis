function paths = matlab_paths()
%MATLAB_PATHS Return paths rooted at this repository, independent of pwd.
configFile = mfilename('fullpath');
configDir = fileparts(configFile);
projectRoot = fileparts(configDir);

paths.root = projectRoot;
paths.raw = fullfile(projectRoot, 'data', 'raw');
paths.interim = fullfile(projectRoot, 'data', 'interim');
paths.processed = fullfile(projectRoot, 'data', 'processed');
paths.external = fullfile(projectRoot, 'data', 'external');
paths.features = fullfile(projectRoot, 'outputs', 'features');
paths.figures = fullfile(projectRoot, 'outputs', 'figures');
paths.models = fullfile(projectRoot, 'outputs', 'models');
paths.reports = fullfile(projectRoot, 'outputs', 'reports');
paths.logs = fullfile(projectRoot, 'outputs', 'logs');
end
