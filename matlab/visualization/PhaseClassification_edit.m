clc;

% --- Open the .fig you want to edit ---
[file, path] = uigetfile('*.fig','Select MATLAB figure');
if isequal(file,0); return; end
fig = openfig(fullfile(path,file),'reuse');

% ============================================================
% 0) Grab axes in visual order (top -> bottom)
% ============================================================
ax = findall(fig,'Type','axes');
ax = flipud(ax);
if isempty(ax), return; end
axTop    = ax(1);
axBottom = ax(end);

% ============================================================
% 1) Rename "Hold→" (or "Hold") xline label -> "End buildup"
% ============================================================
allCL = findall(fig,'Type','ConstantLine');   % xline/yline objects
for k = 1:numel(allCL)
    try
        if isprop(allCL(k),'Label') && isprop(allCL(k).Label,'String')
            s = string(allCL(k).Label.String);
            if strlength(s) > 0 && contains(s,"Hold",'IgnoreCase',true)
                s = regexprep(s, "Hold.*", "End buildup");
                allCL(k).Label.String = char(s);
            end
        end
    catch
    end
end

% ============================================================
% 2) Minimal legend: Buildup / Braking / Release only
%    + Hide all existing plotted objects from legend
% ============================================================
delete(findall(fig,'Type','Legend'));

for i = 1:numel(ax)
    objs = [ ...
        findall(ax(i), 'Type','Line'); ...
        findall(ax(i), 'Type','Scatter'); ...
        findall(ax(i), 'Type','Stair'); ...
        findall(ax(i), 'Type','Area'); ...
        findall(ax(i), 'Type','Bar')];

    for j = 1:numel(objs)
        try
            if isprop(objs(j),'Annotation') && isprop(objs(j).Annotation,'LegendInformation')
                objs(j).Annotation.LegendInformation.IconDisplayStyle = 'off';
            end
            if isprop(objs(j),'HandleVisibility')
                objs(j).HandleVisibility = 'off';
            end
        catch
        end
    end
end

% --- Keep current x-limits safe (datetime ruler can be sensitive) ---
xlim0 = [];
try, xlim0 = xlim(axTop); catch, end

% Colors (match your creation code)
col_buil = [0.00 0.45 0.74];
col_hold = [0.20 0.60 0.20];
col_rel  = [0.85 0.33 0.10];

% datetime-safe dummy handles
isDateAxis = false;
try
    isDateAxis = isa(axTop.XAxis,'matlab.graphics.axis.decorator.DatetimeRuler');
catch
end

if isDateAxis
    xDummy = NaT;  yDummy = NaN;
else
    xDummy = NaN;  yDummy = NaN;
end

hB = plot(axTop, xDummy, yDummy, '-', 'Color', col_buil, 'LineWidth', 2, 'DisplayName','Buildup');
hH = plot(axTop, xDummy, yDummy, '-', 'Color', col_hold, 'LineWidth', 2, 'DisplayName','Braking');
hR = plot(axTop, xDummy, yDummy, '-', 'Color', col_rel , 'LineWidth', 2, 'DisplayName','Release');

lgd = legend(axTop, [hB hH hR], {'Buildup','Braking','Release'}, 'Location','northeast');
lgd.Box = 'on';
lgd.FontSize = 10;

% Restore original limits
try
    if ~isempty(xlim0)
        xlim(axTop, xlim0);
    end
catch
end

% ============================================================
% 3) X labels: show only on bottom subplot
% ============================================================
for i = 1:numel(ax)
    if i < numel(ax)
        xlabel(ax(i), '');
    else
        xlabel(ax(i), 'Time');
    end
end

% ============================================================
% 4) Date handling:
%    - Remove date from ALL upper subplots (time-only tick labels)
%    - Keep date ONLY on bottom subplot (default datetime behavior)
% ============================================================
for i = 1:numel(ax)
    try
        if isa(ax(i).XAxis,'matlab.graphics.axis.decorator.DatetimeRuler')
            if i < numel(ax)
                % upper axes: time only (removes the "Jun 17, 2025" stamp)
                ax(i).XAxis.TickLabelFormat = 'HH:mm:ss';
            else
                % bottom axis: keep default so the date shows once
                ax(i).XAxis.TickLabelFormat = '';  % revert to auto formatting
            end
        end
    catch
    end
end

% ============================================================
% 5) Optional: consistent BC y-limits (matches your earlier intention)
% ============================================================
if numel(ax) >= 2
    bcAx = ax(2:end);
    try
        set(bcAx, 'YLim', [0 1.5]);
    catch
    end
end

% Optional: save/export
% savefig(fig, fullfile(path, ['EDITED_' file]));
% exportgraphics(fig, fullfile(path, ['EDITED_' erase(file,'.fig') '.png']), 'Resolution', 300);