clc;
clear;
close all;

% --- Select and open figure ---
[file, path] = uigetfile('*.fig', 'Select MATLAB figure');
if isequal(file,0)
    return;
end

fig = openfig(fullfile(path,file), 'reuse');

% --- Figure size: enforce consistent export aspect ratio ---
set(fig, 'Units', 'centimeters');
set(fig, 'Position', [2 2 12 6]);   % width 12 cm, height 6 cm (2:1)

% --- Get all axes (exclude legends/colorbars) ---
allAxes = findall(fig, 'Type', 'axes');
allTags = get(allAxes, 'Tag');
if ischar(allTags)
    allTags = {allTags};
end
isDataAx = ~ismember(allTags, {'legend','Colorbar'});
dataAxes = allAxes(isDataAx);

if isempty(dataAxes)
    error('No data axes found in the selected figure.');
end

% Choose a main axes:
% If multiple exist, pick the one with the largest area (robust for subplots)
areas = arrayfun(@(a) prod(a.Position(3:4)), dataAxes);
[~, idx] = max(areas);
ax = dataAxes(idx);

% --- Optional: fix axes margins inside the figure canvas ---
% (If you have multiple subplots, you may want to apply this to all axes instead.)
set(ax, 'Position', [0.12 0.18 0.80 0.72]);

% % --- Set yyaxis labels (if yyaxis exists) ---
% % Activate right axis and set its label
% try
%     yyaxis(ax, 'right');
%     ylabel(ax, 'MBP Pressure [bar]');
% catch
%     % If the figure does not use yyaxis, skip gracefully
% end
% 
% % Activate left axis and (optionally) set its label too
% try
%     yyaxis(ax, 'left');
%     % Uncomment if you want to enforce left label:
%     % ylabel(ax, 'BC Pressure [bar]');
% catch
% end

% --- Consistent fonts and line widths (apply to the selected axes) ---
ax.FontSize  = 10;
ax.LineWidth = 0.8;

% --- Legend formatting (if legend exists) ---
lgd = findobj(fig, 'Type', 'legend');
if ~isempty(lgd)
    lgd(1).FontSize = 10;   % first legend (or change all if needed)
end

% --- Box on for the selected axes ---
box(ax, 'on');

% --- Export (use same base name as input .fig) ---
[~, baseName] = fileparts(file);
outPng = fullfile(path, [baseName '_export.png']);
exportgraphics(fig, outPng, 'Resolution', 300);

fprintf('Exported: %s\n', outPng);