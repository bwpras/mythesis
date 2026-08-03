clc
clear 
close all

load("MovingSummary.mat")
%%
df_pjm = MovingSummary;
if ~isdatetime(df_pjm.Date)
    df_pjm.Date = datetime(df_pjm.Date, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd');
end

% --- Filter only rows where IsMoving = true
moving_df = df_pjm(df_pjm.IsMoving == true, :);

% --- Extract day (remove time part)
moving_df.Day = dateshift(moving_df.Date, 'start', 'day');

% --- Count number of moving records per Folder per Day
movement_counts = groupsummary(moving_df, {'Folder','Day'}, @(x) numel(x), 'IsMoving');
movement_counts.Properties.VariableNames{end} = 'Count';
% groupsummary outputs GroupCount as count

% --- Plot
figure('Position',[100 100 1000 500]);
hold on;

folders = unique(movement_counts.Folder, 'stable');

for idx = 1:numel(folders)
    mask = movement_counts.Folder == folders(idx);
    folder_data = movement_counts(mask,:);

    scatter(folder_data.Day, ...
        repmat(idx, height(folder_data), 1), ...
        folder_data.GroupCount * 20, ... % bubble size
        'filled', 'MarkerFaceAlpha', 0.6);

end

title('Days with Movement per Folder (Dot Size = Movement Counts)');
xlabel('Date');
ylabel('Folder');
yticks(1:numel(folders));
yticklabels(folders);

% Set ticks every 2 days
ax = gca;
ax.XAxis.TickValues = min(movement_counts.Day):days(2):max(movement_counts.Day);
datetick('x','yyyy-mm-dd','keepticks');
xtickangle(45);

grid on;
box on;
hold off;

legend(string(folders), 'Location', 'northeastoutside', 'Title', 'Folder');
