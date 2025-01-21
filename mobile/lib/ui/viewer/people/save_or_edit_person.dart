import 'dart:async';
import "dart:developer";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_result.dart";
import "package:photos/services/search_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/common/date_input.dart";
import "package:photos/ui/common/loading_widget.dart";
import "package:photos/ui/components/action_sheet_widget.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/dialog_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:photos/ui/viewer/file/no_thumbnail_widget.dart";
import "package:photos/ui/viewer/gallery/hooks/pick_person_avatar.dart";
import "package:photos/ui/viewer/people/link_email_screen.dart";
import "package:photos/ui/viewer/people/person_clusters_page.dart";
import "package:photos/ui/viewer/people/person_row_item.dart";
import "package:photos/ui/viewer/search/result/person_face_widget.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/navigation_util.dart";
import "package:photos/utils/toast_util.dart";

class SaveOrEditPerson extends StatefulWidget {
  final String? clusterID;
  final EnteFile? file;
  final bool isEditing;
  final PersonEntity? person;

  const SaveOrEditPerson(
    this.clusterID, {
    super.key,
    this.file,
    this.person,
    this.isEditing = false,
  }) : assert(
          !isEditing || person != null,
          'Person cannot be null when editing',
        );

  @override
  State<SaveOrEditPerson> createState() => _SaveOrEditPersonState();
}

class _SaveOrEditPersonState extends State<SaveOrEditPerson> {
  bool isKeypadOpen = false;
  String _inputName = "";
  String? _selectedDate;
  String? _email;
  bool userAlreadyAssigned = false;
  late final Logger _logger = Logger("_SavePersonState");
  Timer? _debounce;
  List<(PersonEntity, EnteFile)> _cachedPersons = [];
  PersonEntity? person;
  final _nameFocsNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _inputName = widget.person?.data.name ?? "";
    _selectedDate = widget.person?.data.birthDate;
    _email = widget.person?.data.email;
    person = widget.person;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameFocsNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: changed && _inputName.isNotEmpty ? false : true,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) {
          return;
        }

        _nameFocsNode.unfocus();
        final result = await _saveChangesPrompt(context);

        if (result is PersonEntity) {
          if (context.mounted) {
            Navigator.pop(context, result);
          }

          return;
        }

        late final bool shouldPop;
        if (result == ButtonAction.first || result == ButtonAction.second) {
          shouldPop = true;
        } else {
          shouldPop = false;
        }

        if (context.mounted && shouldPop) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: isKeypadOpen,
        appBar: AppBar(
          title: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.isEditing
                  ? context.l10n.editPerson
                  : context.l10n.savePerson,
            ),
          ),
        ),
        body: GestureDetector(
          onTap: () {
            FocusScope.of(context).unfocus();
          },
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(
                      bottom: 32.0,
                      left: 16.0,
                      right: 16.0,
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 48),
                        if (person != null)
                          FutureBuilder<(String, EnteFile)>(
                            future: _getRecentFileWithClusterID(person!),
                            builder: (context, snapshot) {
                              if (snapshot.hasData) {
                                final String personClusterID =
                                    snapshot.data!.$1;
                                final personFile = snapshot.data!.$2;
                                return Stack(
                                  children: [
                                    SizedBox(
                                      height: 110,
                                      width: 110,
                                      child: ClipPath(
                                        clipper: ShapeBorderClipper(
                                          shape: ContinuousRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(80),
                                          ),
                                        ),
                                        child: snapshot.hasData
                                            ? PersonFaceWidget(
                                                key: ValueKey(
                                                  person?.data.avatarFaceID ??
                                                      "",
                                                ),
                                                personFile,
                                                clusterID: personClusterID,
                                                personId: person!.remoteID,
                                              )
                                            : const NoThumbnailWidget(
                                                addBorder: false,
                                              ),
                                      ),
                                    ),
                                    if (person != null)
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(8.0),
                                            boxShadow: Theme.of(context)
                                                .colorScheme
                                                .enteTheme
                                                .shadowMenu,
                                            color: getEnteColorScheme(context)
                                                .backgroundElevated2,
                                          ),
                                          child: IconButton(
                                            icon: const Icon(Icons.edit),
                                            iconSize:
                                                16, // specify the size of the icon
                                            onPressed: () async {
                                              final result =
                                                  await showPersonAvatarPhotoSheet(
                                                context,
                                                person!,
                                              );
                                              if (result != null) {
                                                _logger.info(
                                                  'Person avatar updated',
                                                );
                                                setState(() {
                                                  person = result;
                                                });
                                                Bus.instance.fire(
                                                  PeopleChangedEvent(
                                                    type: PeopleEventType
                                                        .saveOrEditPerson,
                                                    source:
                                                        "_SaveOrEditPersonState",
                                                    person: result,
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              } else {
                                return const SizedBox.shrink();
                              }
                            },
                          ),
                        if (person == null)
                          SizedBox(
                            height: 110,
                            width: 110,
                            child: ClipPath(
                              clipper: ShapeBorderClipper(
                                shape: ContinuousRectangleBorder(
                                  borderRadius: BorderRadius.circular(80),
                                ),
                              ),
                              child: widget.file != null
                                  ? PersonFaceWidget(
                                      widget.file!,
                                      clusterID: widget.clusterID,
                                    )
                                  : const NoThumbnailWidget(
                                      addBorder: false,
                                    ),
                            ),
                          ),
                        const SizedBox(height: 36),
                        TextFormField(
                          keyboardType: TextInputType.name,
                          textCapitalization: TextCapitalization.words,
                          autocorrect: false,
                          focusNode: _nameFocsNode,
                          onChanged: (value) {
                            if (_debounce?.isActive ?? false) {
                              _debounce?.cancel();
                            }
                            _debounce =
                                Timer(const Duration(milliseconds: 300), () {
                              setState(() {
                                _inputName = value;
                              });
                            });
                          },
                          initialValue: _inputName,
                          decoration: InputDecoration(
                            focusedBorder: OutlineInputBorder(
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(8.0)),
                              borderSide: BorderSide(
                                color: getEnteColorScheme(context).strokeMuted,
                              ),
                            ),
                            fillColor: getEnteColorScheme(context).fillFaint,
                            filled: true,
                            hintText: context.l10n.enterName,
                            hintStyle: getEnteTextTheme(context).bodyFaint,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            border: UnderlineInputBorder(
                              borderSide: BorderSide.none,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        DatePickerField(
                          hintText: context.l10n.enterDateOfBirth,
                          firstDate: DateTime(100),
                          lastDate: DateTime.now(),
                          initialValue: _selectedDate,
                          isRequired: false,
                          onChanged: (date) {
                            setState(() {
                              // format date to yyyy-MM-dd
                              _selectedDate =
                                  date?.toIso8601String().split("T").first;
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        _EmailSection(_email, person?.remoteID),
                        const SizedBox(height: 32),
                        ButtonWidget(
                          buttonType: ButtonType.primary,
                          labelText: context.l10n.save,
                          isDisabled: !changed || _inputName.isEmpty,
                          onTap: () async {
                            if (widget.isEditing) {
                              final updatedPersonEntity =
                                  await updatePerson(context);
                              if (updatedPersonEntity != null) {
                                Navigator.pop(context, updatedPersonEntity);
                              }
                            } else {
                              final newPersonEntity = await addNewPerson(
                                context,
                                text: _inputName,
                                clusterID: widget.clusterID!,
                                birthdate: _selectedDate,
                                email: _email,
                              );
                              if (newPersonEntity != null) {
                                Navigator.pop(context, newPersonEntity);
                              }
                            }
                          },
                        ),
                        const SizedBox(height: 32),
                        if (!widget.isEditing) _getPersonItems(),
                        if (widget.isEditing)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              context.l10n.mergedPhotos,
                              style: getEnteTextTheme(context).body,
                            ),
                          ),
                        if (widget.isEditing)
                          Padding(
                            padding:
                                const EdgeInsets.only(bottom: 12.0, top: 24.0),
                            child: PersonClustersWidget(person!),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<dynamic> _saveChangesPrompt(BuildContext context) async {
    PersonEntity? updatedPersonEntity;
    return await showActionSheet(
      body: "Save changes before leaving?",
      context: context,
      buttons: [
        ButtonWidget(
          buttonType: ButtonType.neutral,
          labelText: S.of(context).save,
          isInAlert: true,
          buttonAction: ButtonAction.first,
          shouldStickToDarkTheme: true,
          onTap: () async {
            if (widget.isEditing) {
              updatedPersonEntity = await updatePerson(context);
            } else {
              updatedPersonEntity = await addNewPerson(
                context,
                text: _inputName,
                clusterID: widget.clusterID!,
                birthdate: _selectedDate,
                email: _email,
              );
            }
          },
        ),
        const ButtonWidget(
          buttonType: ButtonType.secondary,
          labelText: "Don't save",
          isInAlert: true,
          buttonAction: ButtonAction.second,
          shouldStickToDarkTheme: true,
        ),
        ButtonWidget(
          buttonType: ButtonType.secondary,
          labelText: S.of(context).cancel,
          isInAlert: true,
          buttonAction: ButtonAction.cancel,
          shouldStickToDarkTheme: true,
        ),
      ],
    ).then((buttonResult) {
      if (buttonResult == null ||
          buttonResult.action == null ||
          buttonResult.action == ButtonAction.cancel) {
        return ButtonAction.cancel;
      } else if (buttonResult.action == ButtonAction.second) {
        return ButtonAction.second;
      } else {
        return updatedPersonEntity;
      }
    });
  }

  Widget _getPersonItems() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 4, 0),
      child: StreamBuilder<List<(PersonEntity, EnteFile)>>(
        stream: _getPersonsWithRecentFileStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            log("Error: ${snapshot.error} ${snapshot.stackTrace}}");
            if (kDebugMode) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snapshot.error}'),
                  Text('${snapshot.stackTrace}'),
                ],
              );
            } else {
              return const SizedBox.shrink();
            }
          } else if (snapshot.hasData) {
            final persons = snapshot.data!;
            final searchResults = _inputName.isNotEmpty
                ? persons
                    .where(
                      (element) => element.$1.data.name
                          .toLowerCase()
                          .contains(_inputName.toLowerCase()),
                    )
                    .toList()
                : persons;
            searchResults.sort(
              (a, b) => a.$1.data.name.compareTo(b.$1.data.name),
            );
            if (searchResults.isEmpty) {
              return const SizedBox.shrink();
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // left align
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 12),
                  child: Text(
                    context.l10n.orMergeWithExistingPerson,
                    style: getEnteTextTheme(context).largeBold,
                  ),
                ),

                SizedBox(
                  height: 160, // Adjust this height based on your needs
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      scrollbars: true,
                    ),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(right: 8),
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final person = searchResults[index];
                        return PersonGridItem(
                          key: ValueKey(person.$1.remoteID),
                          person: person.$1,
                          personFile: person.$2,
                          onTap: () async {
                            if (userAlreadyAssigned) {
                              return;
                            }
                            userAlreadyAssigned = true;
                            await ClusterFeedbackService.instance
                                .addClusterToExistingPerson(
                              person: person.$1,
                              clusterID: widget.clusterID!,
                            );

                            Navigator.pop(context, person);
                          },
                        );
                      },
                      separatorBuilder: (context, index) {
                        return const SizedBox(width: 6);
                      },
                    ),
                  ),
                ),
              ],
            );
          } else {
            return const EnteLoadingWidget();
          }
        },
      ),
    );
  }

  Stream<List<(PersonEntity, EnteFile)>>
      _getPersonsWithRecentFileStream() async* {
    if (_cachedPersons.isEmpty) {
      _cachedPersons = await _getPersonsWithRecentFile();
    }
    yield _cachedPersons;
  }

  Future<PersonEntity?> addNewPerson(
    BuildContext context, {
    String text = '',
    required String clusterID,
    String? birthdate,
    String? email,
  }) async {
    try {
      if (userAlreadyAssigned) {
        return null;
      }
      if (text.trim() == "") {
        return null;
      }
      userAlreadyAssigned = true;
      final personEntity = await PersonService.instance.addPerson(
        name: text,
        clusterID: clusterID,
        birthdate: birthdate,
        email: email,
      );
      final bool extraPhotosFound =
          await ClusterFeedbackService.instance.checkAndDoAutomaticMerges(
        personEntity,
        personClusterID: clusterID,
      );
      if (extraPhotosFound) {
        showShortToast(context, S.of(context).extraPhotosFound);
      }
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "_SaveOrEditPersonState addNewPerson",
          person: personEntity,
        ),
      );
      return personEntity;
    } catch (e) {
      _logger.severe("Error adding new person", e);
      userAlreadyAssigned = false;
      await showGenericErrorDialog(context: context, error: e);
      return null;
    }
  }

  bool get changed => widget.isEditing
      ? (_inputName.trim() != person!.data.name ||
              _selectedDate != person!.data.birthDate) ||
          _email != person!.data.email
      : _inputName.trim().isNotEmpty;

  Future<PersonEntity?> updatePerson(BuildContext context) async {
    try {
      final String name = _inputName.trim();
      final String? birthDate = _selectedDate;
      final personEntity = await PersonService.instance.updateAttributes(
        person!.remoteID,
        name: name,
        birthDate: birthDate,
        email: _email,
      );

      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "_SaveOrEditPersonState updatePerson",
          person: personEntity,
        ),
      );
      return personEntity;
    } catch (e) {
      _logger.severe("Error adding updating person", e);
      await showGenericErrorDialog(context: context, error: e);
      return null;
    }
  }

  Future<List<(PersonEntity, EnteFile)>> _getPersonsWithRecentFile({
    bool excludeHidden = true,
  }) async {
    final persons = await PersonService.instance.getPersons();
    if (excludeHidden) {
      persons.removeWhere((person) => person.data.isIgnored);
    }
    final List<(PersonEntity, EnteFile)> personAndFileID = [];
    for (final person in persons) {
      final clustersToFiles =
          await SearchService.instance.getClusterFilesForPersonID(
        person.remoteID,
      );
      final files = clustersToFiles.values.expand((e) => e).toList();
      if (files.isEmpty) {
        debugPrint(
          "Person ${kDebugMode ? person.data.name : person.remoteID} has no files",
        );
        continue;
      }
      personAndFileID.add((person, files.first));
    }
    return personAndFileID;
  }

  Future<(String, EnteFile)> _getRecentFileWithClusterID(
    PersonEntity person,
  ) async {
    final clustersToFiles =
        await SearchService.instance.getClusterFilesForPersonID(
      person.remoteID,
    );
    int? avatarFileID;
    if (person.data.hasAvatar()) {
      avatarFileID = tryGetFileIdFromFaceId(person.data.avatarFaceID!);
    }
    EnteFile? resultFile;
    // iterate over all clusters and get the first file
    for (final clusterFiles in clustersToFiles.values) {
      for (final file in clusterFiles) {
        if (avatarFileID != null && file.uploadedFileID! == avatarFileID) {
          resultFile = file;
          break;
        }
        resultFile ??= file;
        if (resultFile.creationTime! < file.creationTime!) {
          resultFile = file;
        }
      }
    }
    if (resultFile == null) {
      debugPrint(
        "Person ${kDebugMode ? person.data.name : person.remoteID} has no files",
      );
      return ("", EnteFile());
    }
    return (person.remoteID, resultFile);
  }
}

class _EmailSection extends StatefulWidget {
  final String? personID;
  final String? email;
  const _EmailSection(this.email, this.personID);

  @override
  State<_EmailSection> createState() => _EmailSectionState();
}

class _EmailSectionState extends State<_EmailSection> {
  String? _email;

  @override
  void initState() {
    super.initState();
    _email = widget.email;
  }

  @override
  void didUpdateWidget(covariant _EmailSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.email != widget.email) {
      setState(() {
        _email = widget.email;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_email == null || _email!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 16),
          decoration: BoxDecoration(
            color: getEnteColorScheme(context).fillFaint,
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Expanded(
                  child: ButtonWidget(
                    buttonType: ButtonType.secondary,
                    labelText: "This is me!",
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ButtonWidget(
                    buttonType: ButtonType.primary,
                    labelText: "Link email",
                    shouldSurfaceExecutionStates: false,
                    onTap: () async {
                      final newEmail = await routeToPage(
                        context,
                        LinkEmailScreen(
                          widget.personID,
                          isFromSaveEditPerson: true,
                        ),
                      );
                      if (newEmail != null) {
                        final saveOrEditPersonState = context
                            .findAncestorStateOfType<_SaveOrEditPersonState>()!;
                        saveOrEditPersonState.setState(() {
                          saveOrEditPersonState._email = newEmail as String;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      return TextFormField(
        canRequestFocus: false,
        autocorrect: false,
        decoration: InputDecoration(
          suffixIcon: GestureDetector(
            onTap: _removeLinkFromTextField,
            child: Icon(
              Icons.close_outlined,
              color: getEnteColorScheme(context).strokeMuted,
            ),
          ),
          fillColor: getEnteColorScheme(context).fillFaint,
          filled: true,
          hintText: _email,
          hintStyle: getEnteTextTheme(context).bodyFaint,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: UnderlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  Future<void> _removeLinkFromTextField() async {
    PersonEntity? personEntity;
    if (widget.personID != null) {
      personEntity = await PersonService.instance.getPerson(
        widget.personID!,
      );
    }
    final name = personEntity?.data.name ?? '';
    final email = personEntity?.data.email;
    final result = await showDialogWidget(
      context: context,
      title:
          name.isEmpty ? "Unlink email from person" : "Unlink email from $name",
      icon: Icons.info_outline,
      body: name.isEmpty
          ? "This will unlink $email from this person"
          : "This will unlink $email from $name",
      isDismissible: true,
      buttons: [
        const ButtonWidget(
          buttonAction: ButtonAction.first,
          buttonType: ButtonType.neutral,
          labelText: "Unlink",
          isInAlert: true,
        ),
        ButtonWidget(
          buttonAction: ButtonAction.cancel,
          buttonType: ButtonType.secondary,
          labelText: S.of(context).cancel,
          isInAlert: true,
        ),
      ],
    );

    if (result != null && result.action == ButtonAction.first) {
      final saveOrEditPersonState =
          context.findAncestorStateOfType<_SaveOrEditPersonState>()!;
      saveOrEditPersonState.setState(() {
        saveOrEditPersonState._email = "";
      });
    }
  }
}
