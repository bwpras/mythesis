%% Open the existing figure
fig = openfig('EmergencyBraking.fig','reuse'); % change filename if needed
ax  = gca;

%% Find line objects
lines = findobj(ax,'Type','line');

% Get legend to identify lines
lgd = legend(ax);
labels = lgd.String;

%% Extract data from the lines
for k = 1:numel(lines)
    x{k} = lines(k).XData;
    y{k} = lines(k).YData;
end

%% Clear axes and recreate with dual y-axis
cla(ax)

hold(ax,'on')

for k = 1:numel(lines)

    if contains(labels{k},'MBP')
        yyaxis left
        plot(x{k},y{k},'LineWidth',2)
        ylabel('BC Pressure [bar]')
    else
        yyaxis right
        plot(x{k},y{k},'LineWidth',2)
        ylabel('MBP Pressure [bar]')
    end

end

%% Restore legend and formatting
legend(labels,'Location','best')
grid on
xlabel('Time')
title('Service Braking - Monorail')