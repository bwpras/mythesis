function GroupedEvents = groupIsMovingEvents(MovingSummary)
    GroupedEvents = table();
    groupCounter = 0;
    folders = unique(MovingSummary.Folder);

    for f = 1:length(folders)
        folderName = folders(f);
        rows = MovingSummary(strcmp(MovingSummary.Folder, folderName), :);
        rows = sortrows(rows, 'StartTime');

        startT = rows.StartTime(1);
        endT   = rows.EndTime(1);

        for k = 2:height(rows)
            if rows.StartTime(k) <= endT
                % Extend event
                endT = max(endT, rows.EndTime(k));
            else
                % Save previous event
                groupCounter = groupCounter + 1;
                GroupedEvents(groupCounter,:) = {folderName, ...
                    rows.SensorType(1), rows.Wagon(1), ...
                    startT, endT};
                % Start new event
                startT = rows.StartTime(k);
                endT   = rows.EndTime(k);
            end
        end
        % Final event
        groupCounter = groupCounter + 1;
        GroupedEvents(groupCounter,:) = {folderName, ...
            rows.SensorType(1), rows.Wagon(1), ...
            startT, endT};
    end

    GroupedEvents.Properties.VariableNames = {'Folder','SensorType','Wagon','StartTime','EndTime'};
end
