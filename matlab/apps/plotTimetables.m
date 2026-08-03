function plotTimetables(ax, df_pjm, selectedFolder)
% Ensure Date is datetime
if ~isdatetime(df_pjm.Date)
    df_pjm.Date = datetime(df_pjm.Date, 'ConvertFrom','datenum','Format','yyyy-MM-dd');
end

% Filter rows by selected folder and IsMoving = true
mask = (df_pjm.IsMoving == true) & strcmp(df_pjm.Folder, selectedFolder);
moving_df = df_pjm(mask, :);

if isempty(moving_df)
    cla(ax);
    title(ax, sprintf("No movement data for folder %s", selectedFolder));
    return;
end

% Extract day
moving_df.Day = dateshift(moving_df.Date, 'start','day');

% --- Count number of moving records per Folder per Day
movement_counts = groupsummary(moving_df, {'Folder','Day'}, @(x) numel(x), 'IsMoving');
movement_counts.Properties.VariableNames{end} = 'Count';

% --- Plot into given axes
cla(ax); hold(ax,'on');
scatter(ax, movement_counts.Day, ones(height(movement_counts),1), ...
    movement_counts.GroupCount * 20, 'filled','MarkerFaceAlpha',0.6);

title(ax, sprintf('Days with Movement for %s (Dot Size = Counts)', selectedFolder));
xlabel(ax,'Date'); ylabel(ax,'Folder');
yticks(ax,1); yticklabels(ax,selectedFolder);

% ---- Safe tick handling without datetick ----
if height(movement_counts) >= 1
    tickStart = min(movement_counts.Day);
    tickEnd   = max(movement_counts.Day);

    if tickStart == tickEnd
        % Only one unique day
        ax.XLim = [tickStart-1, tickEnd+1];
        ax.XTick = tickStart;
    else
        ax.XLim = [tickStart-1, tickEnd+1];
        ax.XTick = tickStart:days(2):tickEnd;
    end

    ax.XTickLabelRotation = 45;
    ax.XAxis.TickLabelFormat = 'yyyy-MM-dd';  % formatted datetime labels
end
end
